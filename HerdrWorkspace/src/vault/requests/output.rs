//! Redact before any child output reaches the agent's terminal or tool result.
use base64::{Engine, engine::general_purpose};
use std::{
    ffi::OsString,
    io::{self, Read, Write},
    os::unix::process::ExitStatusExt,
    process::{Command, ExitStatus, Stdio},
    thread,
};

const LIMIT: usize = 1024 * 1024;
const URL_COMPONENT: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~');
const MASK: &[u8] = b"[REDACTED]";
const OVERSIZE: &[u8] = b"[Vault suppressed command output exceeding 1 MiB]\n";

fn forms(values: &[(String, String)]) -> Vec<Vec<u8>> {
    let mut patterns = Vec::new();
    for (_, value) in values {
        let plain = value.as_bytes();
        if plain.is_empty() {
            continue;
        }
        let quoted = serde_json::to_string(value).expect("JSON strings are serializable");
        let encoded = percent_encoding::utf8_percent_encode(value, URL_COMPONENT).to_string();
        patterns.extend([
            plain.to_vec(),
            quoted.as_bytes()[1..quoted.len() - 1].to_vec(),
            encoded.replace("%20", "+").into_bytes(),
            encoded.into_bytes(),
            general_purpose::STANDARD_NO_PAD.encode(plain).into_bytes(),
            general_purpose::URL_SAFE_NO_PAD.encode(plain).into_bytes(),
        ]);
    }
    patterns.sort_unstable();
    patterns.dedup();
    patterns
}

fn redact(input: &[u8], patterns: &[Vec<u8>]) -> Vec<u8> {
    // Group patterns by leading byte. Find every match, including overlapping ones, in one scan.
    let mut by_first: [Vec<&[u8]>; 256] = std::array::from_fn(|_| Vec::new());
    for pattern in patterns {
        by_first[usize::from(pattern[0])].push(pattern);
    }
    let mut output = Vec::with_capacity(input.len());
    let mut through = 0;
    for (i, byte) in input.iter().enumerate() {
        let matched = by_first[usize::from(*byte)]
            .iter()
            .filter(|pattern| input[i..].starts_with(pattern))
            .map(|pattern| pattern.len())
            .max();
        if let Some(length) = matched {
            if i >= through {
                output.extend_from_slice(MASK);
            }
            through = through.max(i + length);
        } else if i >= through {
            output.push(*byte);
        }
    }
    output
}

fn capture(mut source: impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut data = Vec::new();
    (&mut source)
        .take((LIMIT + 1) as u64)
        .read_to_end(&mut data)?;
    if data.len() > LIMIT {
        io::copy(&mut source, &mut io::sink())?;
        return Ok(None);
    }
    Ok(Some(data))
}

fn execute(
    program: OsString,
    args: impl Iterator<Item = OsString>,
    values: &[(String, String)],
) -> io::Result<(ExitStatus, Vec<u8>, Vec<u8>)> {
    let mut child = Command::new(program)
        .args(args)
        .env_remove("SWARMHUB_LAUNCH_KEY")
        .env_remove("SWARMHUB_VAULT_KEY_FILE")
        .envs(values.iter().map(|(name, value)| (name, value)))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stdout = child.stdout.take().expect("piped stdout");
    let stderr = child.stderr.take().expect("piped stderr");
    let output = thread::scope(|threads| {
        let read_stderr = threads.spawn(|| capture(stderr));
        let stdout = capture(stdout);
        let stderr = read_stderr
            .join()
            .map_err(|_| io::Error::other("Vault output reader stopped"))?;
        Ok::<_, io::Error>((stdout?, stderr?))
    });
    let status = child.wait()?;
    let (stdout, stderr) = output?;
    let patterns = forms(values);
    let filter = |stream: Option<Vec<u8>>| match stream {
        Some(stream) => redact(&stream, &patterns),
        None => OVERSIZE.to_vec(),
    };
    Ok((status, filter(stdout), filter(stderr)))
}

pub(super) fn run(
    program: OsString,
    args: impl Iterator<Item = OsString>,
    values: &[(String, String)],
) -> io::Result<i32> {
    let (status, stdout, stderr) = execute(program, args, values)?;
    io::stdout().lock().write_all(&stdout)?;
    io::stderr().lock().write_all(&stderr)?;
    Ok(status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(1)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filters_literal_bytes_json_and_encodings() {
        let value = "fixture\"value #12";
        let values = vec![("TOKEN".to_owned(), value.to_owned())];
        let patterns = forms(&values);
        for representation in &patterns {
            let input = [b"prefix ".as_slice(), representation, b" suffix\xff"].concat();
            assert_eq!(redact(&input, &patterns), b"prefix [REDACTED] suffix\xff");
        }
    }

    #[test]
    fn covers_overlaps_without_rewriting_the_mask() {
        let patterns = [b"abc".to_vec(), b"cde".to_vec(), b"REDACTED".to_vec()];
        assert_eq!(redact(b"abcde", &patterns), MASK);
    }

    #[test]
    fn captures_both_streams_before_returning_any_bytes() {
        let values = vec![(
            "VAULT_FIXTURE".to_owned(),
            "fake-sensitive-value".to_owned(),
        )];
        let script = r#"printf '%s' "${VAULT_FIXTURE%value}"; printf '%s\n' "value"; printf '%s\n' "$VAULT_FIXTURE" >&2; exit 7"#;
        let (status, stdout, stderr) = execute(
            "/bin/sh".into(),
            ["-c", script].into_iter().map(Into::into),
            &values,
        )
        .unwrap();
        assert_eq!(status.code(), Some(7));
        assert_eq!(stdout, b"[REDACTED]\n");
        assert_eq!(stderr, stdout);
    }

    #[test]
    fn oversized_streams_are_discarded_in_full() {
        assert!(capture(vec![b'x'; LIMIT + 1].as_slice()).unwrap().is_none());
        assert_eq!(capture(b"ok".as_slice()).unwrap().unwrap(), b"ok");
    }
}
