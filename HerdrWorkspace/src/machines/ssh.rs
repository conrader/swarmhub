//! What the workspace reads from OpenSSH's own tools, and the checks on what it hands them. Nothing here runs a
//! program or touches a file except `trust`, which adds one line to a known-hosts file.

use base64::{
    Engine,
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD},
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, DirBuilder, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

/// How a machine is reached, as a person writes it for ssh: `box`, `deploy@10.0.0.7`, `deploy@10.0.0.7:2222`,
/// `ssh://deploy@box:2222`. One word that ssh cannot read as an option.
pub(super) fn valid_target(target: &str) -> bool {
    (1..=255).contains(&target.len())
        && !target.starts_with('-')
        && !target.contains("@-")
        && target
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"@._-:/[]%+".contains(&b))
}

/// Herdr Core's rule for a machine's name: 1–32 of a-z 0-9 - _ . starting with a letter or digit, and not shaped
/// like a terminal address (`t7`).
pub(super) fn valid_name(name: &str) -> bool {
    crate::core::valid_name(name)
        && name.as_bytes()[0].is_ascii_alphanumeric()
        && !crate::core::local_address(name)
}

/// What `ssh -G TARGET` says about a target: where ssh would connect and which files it would use.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Resolved {
    pub hostname: String,
    pub port: u16,
    /// `HostKeyAlias`: the name the host's key is filed under instead of the host name.
    pub alias: Option<String>,
    pub user_known_hosts: Vec<PathBuf>,
    pub global_known_hosts: Vec<PathBuf>,
    pub identity_files: Vec<PathBuf>,
    /// Reached through another host or a command, so its key cannot be read from here directly.
    pub proxied: bool,
}

impl Resolved {
    /// The name this host's key is filed under in a known-hosts file.
    pub(super) fn known_name(&self) -> String {
        match (&self.alias, self.port) {
            (Some(alias), _) => alias.clone(),
            (None, 22) => self.hostname.clone(),
            (None, port) => format!("[{}]:{port}", self.hostname),
        }
    }
}

/// A path from ssh's configuration. Older versions print `~/…` as written; a path with `%` tokens is not used.
fn path(text: &str, home: &Path) -> Option<PathBuf> {
    if text.contains('%') {
        None
    } else if let Some(rest) = text.strip_prefix("~/") {
        Some(home.join(rest))
    } else {
        Some(PathBuf::from(text)).filter(|path| path.is_absolute())
    }
}

pub(super) fn resolved(output: &str, home: &Path) -> Option<Resolved> {
    let mut found = Resolved {
        hostname: String::new(),
        port: 22,
        alias: None,
        user_known_hosts: Vec::new(),
        global_known_hosts: Vec::new(),
        identity_files: Vec::new(),
        proxied: false,
    };
    let paths = |value: &str| -> Vec<PathBuf> {
        value
            .split_whitespace()
            .filter_map(|file| path(file, home))
            .collect()
    };
    for line in output.lines() {
        let (key, value) = line.split_once(' ').unwrap_or((line, ""));
        let value = value.trim();
        match key {
            "hostname" => found.hostname = value.to_owned(),
            "port" => found.port = value.parse().ok()?,
            "hostkeyalias" if !value.is_empty() => found.alias = Some(value.to_owned()),
            "userknownhostsfile" => found.user_known_hosts = paths(value),
            "globalknownhostsfile" => found.global_known_hosts = paths(value),
            "identityfile" => found.identity_files.extend(path(value, home)),
            "proxyjump" | "proxycommand" if !value.is_empty() && value != "none" => {
                found.proxied = true;
            }
            _ => {}
        }
    }
    let plain = |name: &str| {
        !name.is_empty()
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-:".contains(&b))
            && !name.starts_with('-')
    };
    (plain(&found.hostname) && found.alias.as_deref().is_none_or(plain)).then_some(found)
}

/// A host's public key: its type and the key itself in base64, as known-hosts files hold them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct HostKey {
    pub kind: String,
    pub key: String,
}

impl HostKey {
    fn read(kind: &str, key: &str) -> Option<Self> {
        let known_kind = kind.starts_with("ssh-")
            || kind.starts_with("ecdsa-")
            || kind.starts_with("sk-")
            || kind.starts_with("rsa-");
        (known_kind && kind.len() <= 64 && fingerprint(key).is_some()).then(|| Self {
            kind: kind.to_owned(),
            key: key.to_owned(),
        })
    }

    pub(super) fn fingerprint(&self) -> String {
        fingerprint(&self.key).unwrap_or_default()
    }
}

/// The fingerprint ssh shows for a key: `SHA256:` and the hash of the key in base64 without padding.
pub(super) fn fingerprint(key: &str) -> Option<String> {
    let bytes = STANDARD
        .decode(key)
        .ok()
        .filter(|bytes| bytes.len() >= 16)?;
    Some(format!(
        "SHA256:{}",
        STANDARD_NO_PAD.encode(Sha256::digest(bytes))
    ))
}

/// The keys in what `ssh-keyscan` printed (`host type key`) or what `ssh-keygen -F` found in a known-hosts file
/// (the same, after `#` lines). Lines for certificate authorities and revoked keys (`@…`) are left out.
pub(super) fn host_keys(output: &str) -> Vec<HostKey> {
    let mut keys: Vec<HostKey> = output
        .lines()
        .filter(|line| !line.starts_with('#') && !line.starts_with('@'))
        .filter_map(|line| {
            let mut words = line.split_whitespace().skip(1);
            HostKey::read(words.next()?, words.next()?)
        })
        .collect();
    // The kind ssh itself prefers first: that is the fingerprint a person is most likely to be shown elsewhere.
    keys.sort_by_key(|key| match key.kind.as_str() {
        "ssh-ed25519" => 0,
        kind if kind.starts_with("ecdsa-") => 1,
        _ => 2,
    });
    keys
}

/// What is known about a host's key before ssh may connect to it without a person.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Standing {
    /// A key the host shows is already in a known-hosts file.
    Trusted,
    /// No key is on file for the host. These are the keys it shows now.
    Unknown(Vec<HostKey>),
    /// Keys are on file for the host, and it shows none of them.
    Changed,
}

pub(super) fn standing(known: &[HostKey], shown: &[HostKey]) -> Standing {
    if known.is_empty() {
        Standing::Unknown(shown.to_vec())
    } else if shown.iter().any(|key| known.contains(key)) {
        Standing::Trusted
    } else {
        Standing::Changed
    }
}

/// Adds one host key to a known-hosts file, making the file (0600) and its folder (0700) if they are missing.
pub(super) fn trust(file: &Path, name: &str, key: &HostKey) -> io::Result<()> {
    if let Some(folder) = file.parent()
        && !folder.exists()
    {
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(folder)?;
    }
    let mut known = OpenOptions::new()
        .read(true)
        .append(true)
        .create(true)
        .mode(0o600)
        .open(file)?;
    if !known.metadata()?.is_file() {
        return Err(io::Error::other("not a regular file"));
    }
    // A last line without its line end would swallow the new one.
    let mut last = *b"\n";
    if known.seek(SeekFrom::End(0))? > 0 {
        known.seek(SeekFrom::End(-1))?;
        known.read_exact(&mut last)?;
    }
    let start = if last == *b"\n" { "" } else { "\n" };
    known.write_all(format!("{start}{name} {} {}\n", key.kind, key.key).as_bytes())
}

/// A public key file's one line, for a person to paste into `authorized_keys` on another machine.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub(super) struct PublicKey {
    /// The public key file on this server.
    pub file: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub fingerprint: String,
    pub comment: String,
    /// The whole line to paste.
    pub public_key: String,
}

pub(super) fn public_key(file: &Path, line: &str) -> Option<PublicKey> {
    let line = line.lines().next()?.trim();
    let mut words = line.splitn(3, ' ');
    let key = HostKey::read(words.next()?, words.next()?)?;
    Some(PublicKey {
        file: file.to_string_lossy().into_owned(),
        fingerprint: key.fingerprint(),
        kind: key.kind,
        comment: words.next().unwrap_or_default().trim().to_owned(),
        public_key: line.to_owned(),
    })
}

/// The public halves of the key pairs among `private`: each private key file that is there with its `.pub` beside
/// it. The private files are only looked for, never opened.
pub(super) fn public_keys(private: &[PathBuf]) -> Vec<PublicKey> {
    let mut keys: Vec<PublicKey> = Vec::new();
    for file in private {
        let public = PathBuf::from(format!("{}.pub", file.display()));
        let pair = fs::metadata(file).is_ok_and(|private| private.is_file())
            && fs::metadata(&public).is_ok_and(|public| public.is_file() && public.len() <= 16_384);
        let Some(key) = pair
            .then(|| fs::read_to_string(&public).ok())
            .flatten()
            .and_then(|line| public_key(&public, &line))
        else {
            continue;
        };
        if !keys.iter().any(|seen| seen.fingerprint == key.fingerprint) {
            keys.push(key);
        }
    }
    keys
}

/// The key files ssh tries by itself, without any configuration.
pub(super) fn default_identities(folder: &Path) -> Vec<PathBuf> {
    [
        "id_ed25519",
        "id_ecdsa",
        "id_rsa",
        "id_ed25519_sk",
        "id_ecdsa_sk",
    ]
    .iter()
    .map(|name| folder.join(name))
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ED: &str = "AAAAC3NzaC1lZDI1NTE5AAAAIOipbKG3Xbyrna8a+F7f0WTZCu93LVsKjwIivQrSro+x";
    const OTHER: &str = "AAAAC3NzaC1lZDI1NTE5AAAAICjzL+q7oE8b0nIkT5d6i+jWRpLf5SHriIQcD1EkKpJt";

    #[test]
    fn a_target_is_one_word_ssh_cannot_read_as_an_option() {
        for target in [
            "box",
            "deploy@10.0.0.7",
            "deploy@10.0.0.7:2222",
            "ssh://deploy@box.example.com:2222",
            "me@[fe80::1%eth0]",
            "a_b+c@host-1",
        ] {
            assert!(valid_target(target), "{target}");
        }
        for target in [
            "",
            "-oProxyCommand=x",
            "me@-oProxyCommand=x",
            "a b",
            "box;id",
            "box\n",
            "$(id)@box",
            "box'",
            "żółw",
            &"a".repeat(256),
        ] {
            assert!(!valid_target(target), "{target}");
        }
    }

    #[test]
    fn a_machine_name_follows_herdr_cores_rule() {
        for name in ["box", "web-1", "10.0.0.7", "a_b.c", "t", "ta1"] {
            assert!(valid_name(name), "{name}");
        }
        for name in [
            "",
            "-box",
            ".box",
            "_box",
            "Box",
            "a b",
            "a/b",
            "t7",
            "t1b",
            &"a".repeat(33),
        ] {
            assert!(!valid_name(name), "{name}");
        }
    }

    #[test]
    fn reads_what_ssh_says_about_a_target() {
        let home = Path::new("/home/me");
        let plain = resolved(
            "user deploy\nhostname 10.0.0.7\nport 22\nidentityfile ~/.ssh/id_rsa\nidentityfile /keys/box\n\
             userknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2\n\
             globalknownhostsfile /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2\nproxyjump none\n",
            home,
        )
        .unwrap();
        assert_eq!(plain.known_name(), "10.0.0.7");
        assert_eq!(
            plain.user_known_hosts,
            [
                PathBuf::from("/home/me/.ssh/known_hosts"),
                PathBuf::from("/home/me/.ssh/known_hosts2")
            ]
        );
        assert_eq!(
            plain.identity_files,
            [
                PathBuf::from("/home/me/.ssh/id_rsa"),
                PathBuf::from("/keys/box")
            ]
        );
        assert!(!plain.proxied && plain.global_known_hosts.len() == 2);

        let odd = resolved(
            "hostname box.example.com\nport 2222\nuserknownhostsfile /home/me/.ssh/%h.known relative\n\
             proxyjump bastion\n",
            home,
        )
        .unwrap();
        assert_eq!(odd.known_name(), "[box.example.com]:2222");
        // A file named with ssh's tokens or without a full path is not one the workspace writes.
        assert!(odd.user_known_hosts.is_empty() && odd.proxied);

        let aliased = resolved("hostname 10.0.0.7\nport 2222\nhostkeyalias box\n", home).unwrap();
        assert_eq!(aliased.known_name(), "box");

        for unusable in [
            "",
            "port 22\n",
            "hostname a b\n",
            "hostname box\nport many\n",
            "hostname -x\n",
        ] {
            assert_eq!(resolved(unusable, home), None, "{unusable}");
        }
    }

    #[test]
    fn reads_host_keys_and_tells_unknown_from_changed() {
        let shown = host_keys(&format!(
            "# 10.0.0.7:22 SSH-2.0-OpenSSH_9.6\n10.0.0.7 ssh-ed25519 {ED}\n10.0.0.7 ssh-rsa not-base64!\n\
             @revoked 10.0.0.7 ssh-ed25519 {OTHER}\nshort\n"
        ));
        assert_eq!(
            shown,
            [HostKey {
                kind: "ssh-ed25519".into(),
                key: ED.into()
            }]
        );
        // The same fingerprint `ssh-keygen -lf` prints for this key.
        assert_eq!(
            shown[0].fingerprint(),
            "SHA256:N0VIHMJ4clw5Dp8u4AHYGjHmWJR7tyZB1csQtj5wu4o"
        );
        // Several kinds come out with Ed25519 first, whatever order the host gave them in.
        let kinds: Vec<String> = host_keys(&format!(
            "h ssh-rsa {ED}\nh ecdsa-sha2-nistp256 {ED}\nh ssh-ed25519 {OTHER}\n"
        ))
        .into_iter()
        .map(|key| key.kind)
        .collect();
        assert_eq!(kinds, ["ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"]);
        // A hashed name, as `ssh-keygen -F` prints a match.
        let on_file = host_keys(&format!(
            "# Host 10.0.0.7 found: line 3\n|1|abc=|def= ssh-ed25519 {ED}\n"
        ));
        assert_eq!(standing(&on_file, &shown), Standing::Trusted);
        assert_eq!(standing(&[], &shown), Standing::Unknown(shown.clone()));
        let other = host_keys(&format!("10.0.0.7 ssh-ed25519 {OTHER}\n"));
        assert_eq!(standing(&on_file, &other), Standing::Changed);
        assert_eq!(standing(&on_file, &[]), Standing::Changed);
    }

    #[test]
    fn trusting_a_key_adds_one_line_to_a_private_file() {
        use std::os::unix::fs::PermissionsExt;
        let scratch = tempfile::tempdir().unwrap();
        let file = scratch.path().join("ssh/known_hosts");
        let key = HostKey {
            kind: "ssh-ed25519".into(),
            key: ED.into(),
        };
        trust(&file, "[box]:2222", &key).unwrap();
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            format!("[box]:2222 ssh-ed25519 {ED}\n")
        );
        assert_eq!(
            fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(file.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        // What was there stays, also when its last line had no line end.
        fs::write(&file, "old ssh-rsa AAAA").unwrap();
        trust(&file, "box", &key).unwrap();
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            format!("old ssh-rsa AAAA\nbox ssh-ed25519 {ED}\n")
        );
        assert!(trust(scratch.path(), "box", &key).is_err());
    }

    #[test]
    fn shows_only_public_keys_whose_private_half_is_there() {
        let scratch = tempfile::tempdir().unwrap();
        let folder = scratch.path();
        fs::write(folder.join("id_ed25519"), "PRIVATE").unwrap();
        fs::write(
            folder.join("id_ed25519.pub"),
            format!("ssh-ed25519 {ED} me@server with spaces\n"),
        )
        .unwrap();
        // A public key alone, and a private key alone, are not pairs.
        fs::write(
            folder.join("id_rsa.pub"),
            format!("ssh-ed25519 {OTHER} x\n"),
        )
        .unwrap();
        fs::write(folder.join("id_ecdsa"), "PRIVATE").unwrap();
        let keys = public_keys(&default_identities(folder));
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].kind, "ssh-ed25519");
        assert_eq!(keys[0].comment, "me@server with spaces");
        assert_eq!(
            keys[0].public_key,
            format!("ssh-ed25519 {ED} me@server with spaces")
        );
        assert!(keys[0].file.ends_with("id_ed25519.pub"));
        assert!(!serde_json::to_string(&keys).unwrap().contains("PRIVATE"));
        assert_eq!(
            public_key(Path::new("x.pub"), "-----BEGIN OPENSSH PRIVATE KEY-----"),
            None
        );
    }
}
