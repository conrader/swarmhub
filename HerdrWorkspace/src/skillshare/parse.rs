//! What skillshare prints, turned into what the workspace sends, and the checks on what the workspace hands to
//! skillshare. Nothing here runs a program or reads a file.

use serde::{Deserialize, Serialize};

/// Skills sent in one answer. `skill_count` still counts them all.
pub(super) const MAX_SKILLS: usize = 500;
pub(super) const MAX_TARGETS: usize = 64;
pub(super) const MAX_NAME: usize = 200;
pub(super) const MAX_PATH: usize = 1_024;
const MAX_DESCRIPTION: usize = 300;
/// Characters of skillshare's own words passed on in `output`, `error` or `problem`.
const MAX_SAID: usize = 2_000;

/// One skill in skillshare's source folder.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub(super) struct Skill {
    /// The name skillshare lists it under, and the name `enable` and `disable` take here.
    pub name: String,
    /// Its folder inside the source.
    pub path: String,
    /// The start of the `description` in its `SKILL.md`, when it has one.
    pub description: Option<String>,
    pub enabled: bool,
    /// `local`, `tracked` (it lives in a Git checkout skillshare updates), or the kind of place it was installed
    /// from, such as `github`.
    pub origin: String,
    /// Where it was installed from, or the tracked checkout it lives in; `null` for a skill made on the server.
    pub source: Option<String>,
}

/// One agent program's skills folder that skillshare links the source into.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub(super) struct Target {
    pub name: String,
    pub path: String,
    pub mode: Option<String>,
    /// skillshare's word for the folder's state, such as `merged` or `not exist`.
    pub status: Option<String>,
    /// Skills from the source that are in the folder now.
    pub linked: u64,
    pub skills_enabled: bool,
}

/// What `skillshare status --json` says, as far as the workspace uses it.
#[derive(Debug, Default, PartialEq)]
pub(super) struct Status {
    pub version: Option<String>,
    pub source: Option<String>,
    pub source_exists: bool,
    pub targets: Vec<Target>,
    /// The folder the agents are kept in, and the Targets that get agents.
    pub agents_source: Option<String>,
    pub agent_targets: Vec<String>,
}

/// What `skillshare sync --json` did, or with `dry_run` would do.
#[derive(Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(default)]
pub(super) struct Synced {
    pub dry_run: bool,
    pub linked: u64,
    pub local: u64,
    pub updated: u64,
    pub pruned: u64,
    #[serde(rename(deserialize = "ignored_count"))]
    pub ignored: u64,
    pub details: Vec<SyncedTarget>,
}

#[derive(Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(default)]
pub(super) struct SyncedTarget {
    pub name: String,
    pub linked: u64,
    pub local: u64,
    pub updated: u64,
    pub pruned: u64,
}

pub(super) fn printable(text: &str, limit: usize) -> bool {
    !text.is_empty() && text.len() <= limit && !text.chars().any(char::is_control)
}

/// The skills in `skillshare list --json`, in its order. `None` when the text is not that list.
pub(super) fn skills(json: &str) -> Option<Vec<Skill>> {
    #[derive(Deserialize)]
    struct Listed {
        name: String,
        kind: Option<String>,
        #[serde(rename = "relPath")]
        path: String,
        #[serde(default)]
        disabled: bool,
        source: Option<String>,
        #[serde(rename = "type")]
        installed_as: Option<String>,
        #[serde(rename = "repoName")]
        repo: Option<String>,
    }
    let listed: Vec<Listed> = serde_json::from_str(json).ok()?;
    Some(
        listed
            .into_iter()
            .filter(|skill| skill.kind.as_deref().is_none_or(|kind| kind == "skill"))
            .filter(|skill| printable(&skill.name, MAX_NAME) && printable(&skill.path, MAX_PATH))
            .map(|skill| {
                let named = |text: Option<String>| text.filter(|text| printable(text, MAX_PATH));
                let (repo, source) = (named(skill.repo), named(skill.source));
                Skill {
                    name: skill.name,
                    path: skill.path,
                    description: None,
                    enabled: !skill.disabled,
                    origin: match (&repo, named(skill.installed_as)) {
                        (Some(_), _) => "tracked".into(),
                        (None, Some(kind)) => kind,
                        (None, None) => "local".into(),
                    },
                    source: repo.or(source),
                }
            })
            .collect(),
    )
}

/// What `skillshare status --json` printed. `None` when the text is not that report.
pub(super) fn status(json: &str) -> Option<Status> {
    #[derive(Deserialize)]
    struct Report {
        version: Option<String>,
        source: Option<Source>,
        #[serde(default)]
        targets: Vec<Listed>,
        agents: Option<Agents>,
    }
    #[derive(Deserialize)]
    struct Agents {
        source: Option<String>,
        #[serde(default)]
        targets: Vec<Named>,
    }
    #[derive(Deserialize)]
    struct Named {
        name: String,
    }
    #[derive(Deserialize)]
    struct Source {
        path: String,
        #[serde(default)]
        exists: bool,
    }
    #[derive(Deserialize)]
    struct Listed {
        name: String,
        #[serde(default)]
        path: String,
        mode: Option<String>,
        status: Option<String>,
        #[serde(default)]
        synced_count: u64,
        skills_enabled: Option<bool>,
    }
    let report: Report = serde_json::from_str(json).ok()?;
    let source = report
        .source
        .filter(|source| printable(&source.path, MAX_PATH));
    let mut targets: Vec<_> = report
        .targets
        .into_iter()
        .filter(|target| printable(&target.name, MAX_NAME) && target.path.len() <= MAX_PATH)
        .take(MAX_TARGETS)
        .map(|target| Target {
            name: target.name,
            path: target.path,
            mode: target.mode.filter(|mode| printable(mode, 40)),
            status: target.status.filter(|status| printable(status, 80)),
            linked: target.synced_count,
            skills_enabled: target.skills_enabled.unwrap_or(true),
        })
        .collect();
    // skillshare lists Targets in a different order from one run to the next.
    targets.sort_by(|a, b| a.name.cmp(&b.name));
    let (agents_source, mut agent_targets) = match report.agents {
        Some(agents) => (
            agents.source.filter(|path| printable(path, MAX_PATH)),
            agents
                .targets
                .into_iter()
                .map(|target| target.name)
                .filter(|name| printable(name, MAX_NAME))
                .take(MAX_TARGETS)
                .collect(),
        ),
        None => (None, Vec::new()),
    };
    agent_targets.sort();
    Some(Status {
        version: report.version.filter(|version| printable(version, 40)),
        source_exists: source.as_ref().is_some_and(|source| source.exists),
        source: source.map(|source| source.path),
        targets,
        agents_source,
        agent_targets,
    })
}

/// What `skillshare sync --json` printed. `None` when the text is not that result.
pub(super) fn synced(json: &str) -> Option<Synced> {
    let mut synced: Synced = serde_json::from_str(json).ok()?;
    synced.details.truncate(MAX_TARGETS);
    synced
        .details
        .retain(|target| printable(&target.name, MAX_NAME));
    synced.details.sort_by(|a, b| a.name.cmp(&b.name));
    Some(synced)
}

/// The version in what `skillshare version` prints, such as `skillshare v0.30.8`.
pub(super) fn version(text: &str) -> Option<String> {
    let version = text.split_whitespace().nth(1)?.strip_prefix('v')?;
    (version.len() <= 40
        && version.starts_with(|first: char| first.is_ascii_digit())
        && version
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+')))
    .then(|| version.to_owned())
}

/// Whether a skill's folder can be handed to `skillshare enable` or `disable` as it is. skillshare reads that
/// argument as a pattern, writes any text it is given into `.skillignore`, and has no way to end its options, so
/// only plain folder names pass: no pattern characters, and nothing that starts like an option.
pub(super) fn plain_path(path: &str) -> bool {
    path.len() <= MAX_NAME
        && path.split('/').all(|part| {
            !part.is_empty()
                && part != "."
                && part != ".."
                && !part.starts_with('-')
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        })
}

/// Whether `name` is shaped like one of skillshare's names for an agent program, such as `claude`.
pub(super) fn agent_name(name: &str) -> bool {
    (1..=32).contains(&name.len())
        && name.as_bytes()[0].is_ascii_alphanumeric()
        && name.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
        })
}

/// The agent programs `skillshare init --discover --dry-run` offers to add as Targets. `None` when the text is not
/// one skillshare is known to print for that command.
pub(super) fn addable(text: &str) -> Option<Vec<String>> {
    let mut lines = text.lines().map(str::trim);
    if lines.clone().any(|line| line == "No new AI tools found") {
        return Some(Vec::new());
    }
    let names = lines.find_map(|line| {
        line.trim_start_matches('✓')
            .trim_start()
            .strip_prefix("Targets")
            .filter(|rest| rest.starts_with(char::is_whitespace))
    })?;
    let mut names: Vec<_> = names
        .split(',')
        .map(str::trim)
        .filter(|name| agent_name(name))
        .take(MAX_TARGETS)
        .map(str::to_owned)
        .collect();
    names.sort();
    (!names.is_empty()).then_some(names)
}

pub(super) fn shortened(text: &str, limit: usize) -> String {
    if text.chars().count() <= limit {
        return text.to_owned();
    }
    let mut short: String = text.chars().take(limit - 1).collect();
    short.push('…');
    short
}

/// What skillshare said, for a person: its two streams without colour codes, its update notice or blank lines,
/// and no longer than a screen.
pub(super) fn said(stdout: &str, stderr: &str) -> String {
    plain(stdout, stderr, MAX_SAID)
}

/// `said` with room for a longer text, such as a diff.
pub(super) fn plain(stdout: &str, stderr: &str, limit: usize) -> String {
    let mut plain = String::new();
    for stream in [stdout, stderr] {
        let mut characters = stream.chars();
        while let Some(character) = characters.next() {
            if character == '\u{1b}' {
                // A colour or cursor code: skip to the letter that ends it.
                for code in characters.by_ref() {
                    if code.is_ascii_alphabetic() {
                        break;
                    }
                }
            } else if character == '\n' || !character.is_control() {
                plain.push(character);
            }
        }
        plain.push('\n');
    }
    let lines: Vec<_> = plain
        .lines()
        .map(str::trim_end)
        .filter(|line| {
            !line.trim().is_empty()
                && !line.contains("Update available")
                && !line.contains("skillshare upgrade")
        })
        .collect();
    shortened(&lines.join("\n"), limit)
}

/// The start of the `description` in the front matter that opens a `SKILL.md`.
pub(super) fn description(file: &str) -> Option<String> {
    let mut lines = file.trim_start_matches('\u{feff}').lines();
    if lines.next()?.trim_end() != "---" {
        return None;
    }
    let mut found: Option<String> = None;
    for line in lines {
        if matches!(line.trim_end(), "---" | "...") {
            break;
        }
        match &mut found {
            None => {
                if let Some(rest) = line.strip_prefix("description:") {
                    let rest = rest.trim();
                    // `|` or `>`, with or without `-` or `+`, says the text is the indented lines that follow.
                    let block = rest.starts_with(['|', '>']) && rest.len() <= 3;
                    found = Some(if block {
                        String::new()
                    } else {
                        rest.to_owned()
                    });
                }
            }
            Some(text) if line.starts_with([' ', '\t']) => {
                text.push(' ');
                text.push_str(line.trim());
            }
            Some(_) if line.trim().is_empty() => {}
            Some(_) => break,
        }
    }
    let found = found?;
    let found = found.trim();
    let quoted = |mark: char| {
        found
            .strip_prefix(mark)
            .and_then(|rest| rest.strip_suffix(mark))
    };
    let text = if let Some(inner) = quoted('"') {
        inner
            .replace("\\\"", "\"")
            .replace("\\n", " ")
            .replace("\\\\", "\\")
    } else if let Some(inner) = quoted('\'') {
        inner.replace("''", "'")
    } else {
        found.to_owned()
    };
    let text = text
        .split(|character: char| character.is_whitespace() || character.is_control())
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    (!text.is_empty()).then(|| shortened(&text, MAX_DESCRIPTION))
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = r#"[
      {"name":"_repo__skills__epsilon","kind":"skill","relPath":"_repo/skills/epsilon","repoName":"_repo"},
      {"name":"group__nested","kind":"skill","relPath":"group/nested"},
      {"name":"beta","kind":"skill","relPath":"beta","disabled":true},
      {"name":"delta","kind":"skill","relPath":"delta","source":"github.com/someone/skills/delta","type":"github","installedAt":"2026-11-16"},
      {"name":"reviewer","kind":"agent","relPath":"reviewer.md"},
      {"name":"bad\u0007name","kind":"skill","relPath":"bad"}
    ]"#;

    #[test]
    fn a_list_becomes_skills_with_their_state_and_origin() {
        let skills = skills(LIST).unwrap();
        let brief: Vec<_> = skills
            .iter()
            .map(|skill| {
                (
                    skill.name.as_str(),
                    skill.path.as_str(),
                    skill.enabled,
                    skill.origin.as_str(),
                    skill.source.as_deref(),
                )
            })
            .collect();
        assert_eq!(
            brief,
            [
                (
                    "_repo__skills__epsilon",
                    "_repo/skills/epsilon",
                    true,
                    "tracked",
                    Some("_repo")
                ),
                ("group__nested", "group/nested", true, "local", None),
                ("beta", "beta", false, "local", None),
                (
                    "delta",
                    "delta",
                    true,
                    "github",
                    Some("github.com/someone/skills/delta")
                ),
            ]
        );
        assert!(super::skills("[]").unwrap().is_empty());
    }

    #[test]
    fn text_that_is_not_a_list_is_not_read_as_one() {
        for text in [
            "",
            "\n✗ config not found: run 'skillshare init' first\n",
            "{\"targets\":[]}",
            "[{\"name\":\"alpha\"}]",
        ] {
            assert!(skills(text).is_none(), "{text}");
        }
    }

    #[test]
    fn a_status_report_gives_the_source_and_each_target() {
        let status = status(
            r#"{"source":{"path":"/home/me/.config/skillshare/skills","exists":true,"skillignore":{"active":false}},
                "skill_count":50,"tracked_repos":[],
                "targets":[
                  {"name":"universal","path":"/home/me/.agents/skills","mode":"merge","status":"merged","synced_count":50,"include":[],"exclude":[],"skills_enabled":true},
                  {"name":"claude","path":"/home/me/.claude/skills","mode":"merge","status":"not exist","synced_count":0,"skills_enabled":false}],
                "agents":{"count":0},"version":"0.30.8"}"#,
        )
        .unwrap();
        assert_eq!(status.version.as_deref(), Some("0.30.8"));
        assert_eq!(
            status.source.as_deref(),
            Some("/home/me/.config/skillshare/skills")
        );
        assert!(status.source_exists);
        // By name, however skillshare ordered them this time.
        assert_eq!(
            status.targets,
            [
                Target {
                    name: "claude".into(),
                    path: "/home/me/.claude/skills".into(),
                    mode: Some("merge".into()),
                    status: Some("not exist".into()),
                    linked: 0,
                    skills_enabled: false,
                },
                Target {
                    name: "universal".into(),
                    path: "/home/me/.agents/skills".into(),
                    mode: Some("merge".into()),
                    status: Some("merged".into()),
                    linked: 50,
                    skills_enabled: true,
                },
            ]
        );
        assert_eq!(status.agents_source, None);
        assert!(status.agent_targets.is_empty());
        assert_eq!(super::status("{}").unwrap(), Status::default());
        assert!(super::status("✗ config not found: run 'skillshare init' first").is_none());
    }

    #[test]
    fn a_status_report_keeps_only_so_many_targets() {
        let targets: Vec<_> = (0..MAX_TARGETS + 9)
            .map(|index| format!(r#"{{"name":"t{index}","path":"/t/{index}"}}"#))
            .collect();
        let status = status(&format!(r#"{{"targets":[{}]}}"#, targets.join(","))).unwrap();
        assert_eq!(status.targets.len(), MAX_TARGETS);
    }

    #[test]
    fn a_sync_result_is_read_with_each_target() {
        let synced = synced(
            r#"{"targets":1,"linked":5,"local":0,"updated":0,"pruned":1,"ignored_count":1,"ignored_skills":["alpha"],
                "dry_run":true,"duration":"4ms",
                "details":[{"name":"claude","mode":"merge","linked":5,"local":0,"updated":0,"pruned":1}],
                "context_cost":{"groups":[]}}"#,
        )
        .unwrap();
        assert_eq!(
            synced,
            Synced {
                dry_run: true,
                linked: 5,
                local: 0,
                updated: 0,
                pruned: 1,
                ignored: 1,
                details: vec![SyncedTarget {
                    name: "claude".into(),
                    linked: 5,
                    local: 0,
                    updated: 0,
                    pruned: 1
                }],
            }
        );
        assert_eq!(
            serde_json::to_value(&synced).unwrap()["ignored"],
            serde_json::json!(1)
        );
        assert!(super::synced("✓ Synced 4 skills to 1 target").is_none());
    }

    #[test]
    fn the_version_is_read_from_the_version_line() {
        assert_eq!(version("skillshare v0.30.8\n").as_deref(), Some("0.30.8"));
        assert_eq!(
            version("skillshare v1.2.3-rc.1").as_deref(),
            Some("1.2.3-rc.1")
        );
        for text in [
            "",
            "skillshare",
            "skillshare 0.30.8",
            "skillshare v<script>",
            "bash: skillshare: not found",
        ] {
            assert!(version(text).is_none(), "{text}");
        }
    }

    #[test]
    fn only_plain_folder_names_are_handed_to_enable_and_disable() {
        for path in [
            "humanizer",
            "shopify-admin",
            "group/nested",
            "_repo/skills/epsilon",
            "v1.2_x",
        ] {
            assert!(plain_path(path), "{path}");
        }
        for path in [
            "",
            "-n",
            "--dry-run",
            "group/-p",
            "draft-*",
            "a?",
            "[ab]",
            "!keep",
            "#note",
            "two words",
            "a\nb",
            "../outside",
            "group/../x",
            "./x",
            "/absolute",
            "trailing/",
            "a//b",
            "naïve",
            "a;b",
            "$(x)",
        ] {
            assert!(!plain_path(path), "{path}");
        }
        assert!(!plain_path(&"a".repeat(MAX_NAME + 1)));
    }

    #[test]
    fn agent_names_are_short_lower_case_words() {
        for name in ["claude", "codex", "universal", "github-copilot", "pi_2"] {
            assert!(agent_name(name), "{name}");
        }
        for name in [
            "", "Claude", "-g", "--select", "_x", "a b", "a,b", "a/b", "../x", "claude\n",
        ] {
            assert!(!agent_name(name), "{name}");
        }
        assert!(!agent_name(&"a".repeat(33)));
    }

    #[test]
    fn the_agent_programs_skillshare_offers_are_read_from_its_dry_run() {
        assert_eq!(
            addable(
                "Found 3 new AI tools\n✓ Targets  gemini, claude, universal\nDry run — nothing was written\n"
            )
            .unwrap(),
            ["claude", "gemini", "universal"]
        );
        assert_eq!(addable("No new AI tools found\n\n").unwrap(), [""; 0]);
        assert_eq!(
            addable("Found 1 new AI tools\n✓ Targets  claude, --force, Bad Name\n").unwrap(),
            ["claude"]
        );
        for text in [
            "",
            "✗ config not found: run 'skillshare init' first",
            "✓ Targetsclaude",
            "✓ Targets  none (--targets, --no-targets)",
        ] {
            assert!(addable(text).is_none(), "{text}");
        }
    }

    #[test]
    fn what_skillshare_said_is_passed_on_plain_and_bounded() {
        assert_eq!(
            said(
                "\u{1b}[32m✓\u{1b}[0m beta      added to .skillignore\n\nNext\n  skillshare sync  apply the change\n\n",
                "\n! Update available: 0.30.8 -> 0.30.9\n  Run 'skillshare upgrade' to update\n"
            ),
            "✓ beta      added to .skillignore\nNext\n  skillshare sync  apply the change"
        );
        assert_eq!(said("", "\n✗ unknown flag: --\r\n"), "✗ unknown flag: --");
        assert_eq!(said("", ""), "");
        let long = said(&"x".repeat(MAX_SAID * 3), "");
        assert_eq!(long.chars().count(), MAX_SAID);
        assert!(long.ends_with('…'));
    }

    #[test]
    fn a_description_is_read_from_the_front_matter() {
        let read = |front: &str| description(&format!("---\nname: x\n{front}\n---\n\n# X\n"));
        assert_eq!(
            read("description: Use when testing.").as_deref(),
            Some("Use when testing.")
        );
        assert_eq!(
            read("description: \"Quoted: with a \\\"word\\\" inside.\"\nlicense: MIT").as_deref(),
            Some("Quoted: with a \"word\" inside.")
        );
        assert_eq!(
            read("description: 'It''s single quoted.'").as_deref(),
            Some("It's single quoted.")
        );
        assert_eq!(
            read("description: |\n  First line.\n  Second line.\nlicense: MIT").as_deref(),
            Some("First line. Second line.")
        );
        assert_eq!(
            read("description: >-\n  Folded over\n\n  two lines.\nmetadata:\n  version: 1")
                .as_deref(),
            Some("Folded over two lines.")
        );
        assert_eq!(
            read("description: A plain one that\n  goes on.").as_deref(),
            Some("A plain one that goes on.")
        );
        assert_eq!(
            description("\u{feff}---\r\ndescription: Windows line ends.\r\n---\r\n").as_deref(),
            Some("Windows line ends.")
        );
        // A file cut off inside its front matter still gives what was read.
        assert_eq!(
            description("---\ndescription: Cut off he").as_deref(),
            Some("Cut off he")
        );
    }

    #[test]
    fn a_missing_description_is_none_and_a_long_one_is_cut() {
        for file in [
            "",
            "# No front matter\n\ndescription: not this one\n",
            "---\nname: x\n---\ndescription: after the front matter\n",
            "---\nname: x\ndescription:\n---\n",
            "---\nname: x\ndescription: \"\"\n---\n",
            "---\nmetadata:\n  description: nested, so not the skill's\n---\n",
        ] {
            assert!(description(file).is_none(), "{file}");
        }
        let long =
            description(&format!("---\ndescription: {}\n---\n", "word ".repeat(200))).unwrap();
        assert_eq!(long.chars().count(), MAX_DESCRIPTION);
        assert!(long.ends_with('…'));
    }
}
