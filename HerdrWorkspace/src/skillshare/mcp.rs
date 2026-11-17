//! One MCP server's settings, read out of the file skillshare keeps them in, for a preview. skillshare has no
//! command that prints a server's settings, so this reads the YAML it writes: block style, one server under
//! `servers:`. It is not a YAML reader. What it does not understand it leaves out, and what could hold a secret is
//! never passed on: environment and header values and the token are replaced by their names here, on the server,
//! an address loses its query and sign-in part, and an argument that follows a flag named like a key or a token
//! is masked.

use super::read::unquoted;
use serde::Serialize;

const MASK: &str = "•••";
const MAX_VALUE: usize = 400;
const MAX_PARTS: usize = 40;

/// One line of a preview: what it is, its value, and whether the value only names what stays on the server.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub(super) struct Setting {
    pub key: String,
    pub value: String,
    pub hidden: bool,
}

impl Setting {
    pub(super) fn shown(key: &str, value: impl Into<String>) -> Self {
        Self {
            key: key.into(),
            value: super::parse::shortened(&value.into(), MAX_VALUE),
            hidden: false,
        }
    }

    fn hidden(key: &str, names: &[String]) -> Self {
        Self {
            key: key.into(),
            value: super::parse::shortened(&names.join(", "), MAX_VALUE),
            hidden: true,
        }
    }
}

/// A line that is not blank or a comment: how far it is indented, and its text.
struct Line<'a> {
    indent: usize,
    text: &'a str,
}

fn lines(file: &str) -> Vec<Line<'_>> {
    file.lines()
        .filter_map(|line| {
            let text = line.trim();
            (!text.is_empty() && !text.starts_with('#')).then(|| Line {
                indent: line.len() - line.trim_start_matches(' ').len(),
                text,
            })
        })
        .collect()
}

/// `key: value` or `key:`, with the key unquoted and a trailing comment dropped from a plain value.
fn pair(text: &str) -> Option<(&str, &str)> {
    let (key, value) = match text.split_once(": ") {
        Some((key, value)) => (key, value.trim()),
        None => (text.strip_suffix(':')?, ""),
    };
    let key = unquoted(key);
    let value = if value.starts_with(['"', '\'']) {
        value
    } else {
        value.split(" #").next().unwrap_or(value).trim_end()
    };
    (!key.is_empty() && !key.starts_with("- ")).then_some((key, value))
}

/// The name at the start of a mapping's line, and nothing of its value.
fn name_of(text: &str) -> String {
    let key = pair(text).map_or(text, |(key, _)| key);
    let key = key.split(['=', ':', ' ']).next().unwrap_or("");
    let plain = key
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'));
    if plain { key.to_owned() } else { String::new() }
}

/// The entries of a list, or with `keys` the names in a mapping, written under a key: on the indented lines that
/// follow it, or for a list in brackets on the key's own line. A mapping written on one line is not read, because
/// a value with a comma in it would be taken for a name.
fn parts(inline: &str, nested: &[Line<'_>], keys: bool) -> Vec<String> {
    let found: Vec<String> = if !inline.is_empty() {
        let inside = inline
            .strip_prefix('[')
            .and_then(|rest| rest.strip_suffix(']'));
        match inside {
            Some(inside) if !keys => inside
                .split(',')
                .map(|part| unquoted(part).to_owned())
                .collect(),
            _ => return Vec::new(),
        }
    } else {
        let Some(first) = nested.first().map(|line| line.indent) else {
            return Vec::new();
        };
        nested
            .iter()
            .filter(|line| line.indent == first)
            .map(|line| {
                let text = line.text.strip_prefix("- ").unwrap_or(line.text).trim();
                if keys {
                    name_of(text)
                } else {
                    unquoted(text).to_owned()
                }
            })
            .collect()
    };
    found
        .into_iter()
        .filter(|part| !part.is_empty())
        .take(MAX_PARTS)
        .collect()
}

/// A name that says its value is a secret.
fn secretive(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    [
        "key",
        "token",
        "secret",
        "password",
        "passwd",
        "auth",
        "credential",
        "bearer",
        "cookie",
        "session",
    ]
    .iter()
    .any(|word| name.contains(word))
}

/// An address without what may sign in: no user and password, no query, nothing after `#`.
pub(super) fn endpoint(address: &str) -> String {
    let address = address.split(['?', '#']).next().unwrap_or(address);
    match address.split_once("://") {
        Some((scheme, rest)) => {
            let host_end = rest.find('/').unwrap_or(rest.len());
            let host = &rest[..host_end];
            let host = host.rsplit('@').next().unwrap_or(host);
            format!("{scheme}://{host}{}", &rest[host_end..])
        }
        None => address.to_owned(),
    }
}

/// A command's arguments as they may be shown.
fn arguments(arguments: Vec<String>) -> Vec<String> {
    let mut mask_next = false;
    arguments
        .into_iter()
        .map(|argument| {
            // What follows a flag named like a secret is one, whatever it looks like.
            if std::mem::take(&mut mask_next) {
                return MASK.to_owned();
            }
            if let Some((name, value)) = argument.split_once('=')
                && (argument.starts_with('-') || !name.contains(['/', ':', ' ']))
            {
                return if secretive(name) {
                    format!("{name}={MASK}")
                } else {
                    format!("{name}={}", endpoint(value))
                };
            }
            if argument.starts_with('-') {
                mask_next = secretive(&argument);
                argument
            } else {
                endpoint(&argument)
            }
        })
        .collect()
}

/// The settings of the server called `name` in `file`, or `None` when the file has no such server.
pub(super) fn server(file: &str, name: &str) -> Option<Vec<Setting>> {
    let lines = lines(file);
    // The file can hold several lists of servers (the global one, and one for each project root): the first that
    // names this server is the one.
    let (start, depth) = lines.iter().enumerate().find_map(|(at, line)| {
        if pair(line.text) != Some(("servers", "")) {
            return None;
        }
        let children = lines[at + 1..]
            .iter()
            .take_while(|child| child.indent > line.indent);
        let depth = lines
            .get(at + 1)
            .filter(|child| child.indent > line.indent)?
            .indent;
        children
            .enumerate()
            .find(|(_, child)| {
                child.indent == depth && pair(child.text).is_some_and(|(key, _)| key == name)
            })
            .map(|(offset, _)| (at + 1 + offset, depth))
    })?;
    let block: Vec<&Line<'_>> = lines[start + 1..]
        .iter()
        .take_while(|line| line.indent > depth)
        .collect();
    let Some(field) = block.first().map(|line| line.indent) else {
        // Written on one line, or empty: nothing this reads.
        return Some(Vec::new());
    };
    let mut settings = Vec::new();
    for (at, line) in block
        .iter()
        .enumerate()
        .filter(|(_, line)| line.indent == field)
    {
        let Some((key, value)) = pair(line.text) else {
            continue;
        };
        let nested: Vec<Line<'_>> = block[at + 1..]
            .iter()
            .take_while(|below| below.indent > field)
            .map(|below| Line {
                indent: below.indent,
                text: below.text,
            })
            .collect();
        // A value spread over the following lines as a block of text is not one this shows.
        let scalar = (!value.is_empty() && !value.starts_with(['|', '>', '{', '[']))
            .then(|| unquoted(value));
        match key {
            "command" | "transport" => {
                if let Some(value) = scalar {
                    settings.push(Setting::shown(key, value));
                }
            }
            "url" => {
                if let Some(value) = scalar {
                    settings.push(Setting::shown(key, endpoint(value)));
                }
            }
            "args" => {
                let shown = arguments(parts(value, &nested, false));
                if !shown.is_empty() {
                    settings.push(Setting::shown(key, shown.join(" ")));
                }
            }
            "env" | "headers" => settings.push(Setting::hidden(key, &parts(value, &nested, true))),
            "bearerToken" => settings.push(Setting::hidden("bearer_token", &[])),
            "tools" => {
                let Some(inner) = nested.first().map(|line| line.indent) else {
                    continue;
                };
                for (at, rule) in nested
                    .iter()
                    .enumerate()
                    .filter(|(_, rule)| rule.indent == inner)
                {
                    let Some((which @ ("allow" | "deny"), listed)) = pair(rule.text) else {
                        continue;
                    };
                    let below: Vec<Line<'_>> = nested[at + 1..]
                        .iter()
                        .take_while(|line| line.indent > inner)
                        .map(|line| Line {
                            indent: line.indent,
                            text: line.text,
                        })
                        .collect();
                    let names = parts(listed, &below, false);
                    if !names.is_empty() {
                        settings.push(Setting::shown(&format!("tools_{which}"), names.join(", ")));
                    }
                }
            }
            _ => {}
        }
    }
    Some(settings)
}

/// One line about a server for a list: what it runs, or where it connects to.
pub(super) fn summary(settings: &[Setting]) -> Option<String> {
    let value = |key: &str| {
        settings
            .iter()
            .find(|setting| setting.key == key)
            .map(|setting| setting.value.as_str())
    };
    if let Some(command) = value("command") {
        let program = command.rsplit('/').next().unwrap_or(command);
        return Some(format!("Runs {program} on the server"));
    }
    let url = value("url")?;
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    Some(format!(
        "Connects to {}",
        rest.split('/').next().unwrap_or(rest)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = include_str!("fixtures/mcp-source.yaml");

    fn brief(settings: &[Setting]) -> Vec<(&str, &str, bool)> {
        settings
            .iter()
            .map(|setting| (setting.key.as_str(), setting.value.as_str(), setting.hidden))
            .collect()
    }

    #[test]
    fn a_server_is_read_from_the_file_skillshare_writes() {
        let local = server(SOURCE, "local").unwrap();
        assert_eq!(
            brief(&local),
            [
                ("command", "company-mcp", false),
                ("env", "API_KEY, LOG_LEVEL, REGION", true),
                ("args", "--workspace /srv/work", false),
            ]
        );
        assert_eq!(
            summary(&local).as_deref(),
            Some("Runs company-mcp on the server")
        );
        let docs = server(SOURCE, "docs").unwrap();
        assert_eq!(
            brief(&docs),
            [
                ("url", "https://example.com/mcp", false),
                ("headers", "X-Team", true),
                ("bearer_token", "", true),
            ]
        );
        assert_eq!(summary(&docs).as_deref(), Some("Connects to example.com"));
        assert!(server(SOURCE, "missing").is_none());
        assert!(server("", "docs").is_none());
        assert!(server("mcp:\n  servers:\n", "docs").is_none());
    }

    #[test]
    fn no_value_that_could_be_a_secret_is_passed_on() {
        let file = "\
# a comment
mcp:
  servers:
    \"risky\":
      command: /opt/bin/tool # the program
      args:
        - --api-key
        - sk-live-ARGSECRET
        - --token=tok-INLINESECRET
        - PASSWORD=pw-ENVSECRET
        - --endpoint=https://user:pw-URLSECRET@api.example.com/v1?sig=QUERYSECRET
        - https://example.com/hook?access=QUERYSECRET2#frag
        - plain
      env: {OPENAI_API_KEY: sk-FLOWSECRET, REGION: eu}
      headers:
        Authorization: Bearer hdr-SECRET
        X-Team:
          fromEnv: TEAM
      bearerToken:
        fromEnv: DOCS_TOKEN
      options:
        codex:
          secret_setting: opt-SECRET
      note: |
        block-SECRET
      tools:
        allow: [read_*, search]
        deny:
          - delete_*
    other:
      url: https://u:p-OTHERSECRET@example.org/mcp?key=OTHERQUERY
";
        let risky = server(file, "risky").unwrap();
        assert_eq!(
            brief(&risky),
            [
                ("command", "/opt/bin/tool", false),
                (
                    "args",
                    "--api-key ••• --token=••• PASSWORD=••• --endpoint=https://api.example.com/v1 https://example.com/hook plain",
                    false
                ),
                // Written on one line: not read, so not even the names are guessed.
                ("env", "", true),
                ("headers", "Authorization, X-Team", true),
                ("bearer_token", "", true),
                ("tools_allow", "read_*, search", false),
                ("tools_deny", "delete_*", false),
            ]
        );
        assert_eq!(summary(&risky).as_deref(), Some("Runs tool on the server"));
        let other = server(file, "other").unwrap();
        assert_eq!(brief(&other), [("url", "https://example.org/mcp", false)]);
        let sent = format!("{risky:?}{other:?}");
        assert!(
            !sent.contains("SECRET") && !sent.contains("QUERY"),
            "{sent}"
        );
    }

    #[test]
    fn what_is_not_understood_is_left_out() {
        // One line for the whole server, a block of text for a value, and a list where a mapping belongs.
        assert_eq!(
            server("servers:\n  one: {command: x, env: {A: s3cret}}\n", "one"),
            Some(Vec::new())
        );
        let odd = server(
            "servers:\n  two:\n    command: |\n      run-SECRET\n    url: >-\n      https://x\n    env:\n      - A=s3cret\n      - B: x,y=SECRET\n    args: [--password, -x=SECRET, ok]\n",
            "two",
        )
        .unwrap();
        assert_eq!(
            brief(&odd),
            [("env", "A, B", true), ("args", "--password ••• ok", false)]
        );
        // The second list of servers is found when the first does not name the server.
        let two = "mcp:\n  servers:\n    a:\n      command: one\n  projects:\n    /srv/shop:\n      servers:\n        b:\n          command: two\n";
        assert_eq!(
            brief(&server(two, "b").unwrap()),
            [("command", "two", false)]
        );
        assert_eq!(
            brief(&server(two, "a").unwrap()),
            [("command", "one", false)]
        );
    }

    #[test]
    fn an_address_loses_its_sign_in_and_query() {
        for (address, shown) in [
            ("https://example.com/mcp", "https://example.com/mcp"),
            (
                "https://user:pass@example.com:8443/mcp?token=x#y",
                "https://example.com:8443/mcp",
            ),
            ("http://a@b@host/p", "http://host/p"),
            ("/srv/work", "/srv/work"),
            ("name?x", "name"),
        ] {
            assert_eq!(endpoint(address), shown, "{address}");
        }
    }
}
