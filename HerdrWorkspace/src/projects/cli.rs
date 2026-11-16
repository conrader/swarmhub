//! `swarmhub-herdr project …`, run by an agent in its own terminal. Like `helper`, it only asks the running
//! workspace and prints the answer; which projects there are, and where, is the workspace's knowledge.

use super::{Ask, WRITE_BYTES};
use crate::helpers::{Action, cli as road};
use std::{
    io::{Read, Write},
    time::Duration,
};

pub(crate) const USAGE: &str = "Projects (folders on other machines that this agent was given; everything below happens there, not here):
  swarmhub-herdr project list
  swarmhub-herdr project run NAME [--timeout SECONDS] -- COMMAND [ARG...]
      Runs in the project's folder and exits with the command's exit code. One word after `--` is a line for
      that machine's shell, as in -- \"cd src && make test\"; several words are a program and its arguments as
      given. 120 seconds unless --timeout says otherwise, at most 600.
  swarmhub-herdr project read NAME PATH [--offset LINE] [--limit LINES]
  swarmhub-herdr project write NAME PATH      the whole new content on standard input (text, up to 128 KB)
  swarmhub-herdr project edit NAME PATH --old TEXT --new TEXT [--old TEXT --new TEXT]...
      Each old text must be in the file exactly once; all replacements are made or none.
  PATH is inside the project's folder: src/main.rs, never /etc/hosts or ../x.";

/// The end of `project list`: how to use what it listed.
pub(super) const HOW: &str = "Run a command in one: swarmhub-herdr project run NAME -- COMMAND [ARG...]
Read, write or change a file: swarmhub-herdr project read|write|edit NAME PATH (see swarmhub-herdr project --help)";
pub(super) const PATH_SHAPE: &str = "Give the file's path inside the project's folder, such as src/main.rs: not a full path, and without `..`.";
pub(super) const WRITE_SHAPE: &str = "That is more than 128 KB. Write a file this large in parts on the machine with `project run`, or change it with `project edit`.";

const OFFLINE: &str = "The SwarmHub workspace server is not running, so projects on other machines are unavailable. Nothing was run or changed.";
const BLOCKED: &str = "A sandbox stopped this command from reaching the SwarmHub workspace, and it found no .swarmhub-helpers folder it may write to. Nothing was run or changed. Run the command from the folder this agent was started in.";
const SILENT: &str = "The workspace did not answer in time. A command may still be running on the project's machine: look before you run it again.";
/// The exit code when the project command itself could not do its work, as distinct from the code of a command
/// that ran on the project's machine.
const FAILED: i32 = 125;
/// How long the workspace may take beyond a command's own time limit.
const MARGIN: Duration = Duration::from_secs(45);
const PATIENCE: Duration = Duration::from_secs(60);

#[derive(Debug, PartialEq, Eq)]
enum Command {
    Ask(Ask, Duration),
    Help,
}

fn number(name: &str, value: Option<&String>) -> Result<u64, String> {
    value
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|count| *count > 0)
        .ok_or_else(|| format!("--{name} takes a whole number above zero."))
}

/// Splits `--name value` and `--name=value`.
fn option<'a>(
    arg: &'a str,
    rest: &mut impl Iterator<Item = &'a String>,
) -> Option<(&'a str, Option<&'a String>, Option<&'a str>)> {
    let option = arg.strip_prefix("--")?;
    Some(match option.split_once('=') {
        Some((name, value)) => (name, None, Some(value)),
        None => (option, rest.next(), None),
    })
}

/// The arguments after `project`. `stdin` supplies the content for `write`.
fn parse(
    args: &[String],
    stdin: impl FnOnce() -> Result<String, String>,
) -> Result<Command, String> {
    let Some((verb, rest)) = args.split_first() else {
        return Ok(Command::Help);
    };
    let named = |words: &[&String], most: usize, what: &str| -> Result<(), String> {
        if words.is_empty() {
            Err(format!("Name the project.\n{USAGE}"))
        } else if words.len() < most {
            Err(format!("{what}\n{USAGE}"))
        } else if words.len() > most {
            Err(format!("Too many words for this command.\n{USAGE}"))
        } else {
            Ok(())
        }
    };
    match verb.as_str() {
        "--help" | "-h" | "help" => Ok(Command::Help),
        "list" if rest.is_empty() => Ok(Command::Ask(Ask::List, PATIENCE)),
        "list" => Err(format!("`project list` takes nothing more.\n{USAGE}")),
        "run" => {
            // Options are read only before the command starts: what follows belongs to the command.
            let mut seconds = None;
            let mut project = None;
            let mut at = 0;
            while let Some(arg) = rest.get(at) {
                if arg == "--" {
                    at += 1;
                    break;
                } else if arg == "--timeout" {
                    seconds = Some(number("timeout", rest.get(at + 1))?);
                    at += 2;
                } else if let Some(value) = arg.strip_prefix("--timeout=") {
                    seconds = Some(number("timeout", Some(&value.to_owned()))?);
                    at += 1;
                } else if project.is_none() && !arg.starts_with('-') {
                    project = Some(arg.clone());
                    at += 1;
                } else if project.is_none() {
                    return Err(format!(
                        "{} is not an option of `project run`.\n{USAGE}",
                        arg.chars().take(40).collect::<String>()
                    ));
                } else {
                    break;
                }
            }
            let project = project.ok_or_else(|| format!("Name the project.\n{USAGE}"))?;
            let command: Vec<String> = rest.get(at..).unwrap_or_default().to_vec();
            if command.is_empty() {
                return Err(format!("Give the command to run after `--`.\n{USAGE}"));
            }
            let limit = seconds
                .unwrap_or(super::RUN_SECONDS)
                .min(super::MAX_RUN_SECONDS);
            Ok(Command::Ask(
                Ask::Run {
                    project,
                    command,
                    seconds,
                },
                Duration::from_secs(limit) + MARGIN,
            ))
        }
        "read" => {
            let (mut words, mut offset, mut limit) = (Vec::new(), None, None);
            let mut rest = rest.iter();
            while let Some(arg) = rest.next() {
                match option(arg, &mut rest) {
                    Some((name @ ("offset" | "limit"), value, inline)) => {
                        let inline = inline.map(str::to_owned);
                        let count = number(name, inline.as_ref().or(value))? as usize;
                        *(if name == "offset" {
                            &mut offset
                        } else {
                            &mut limit
                        }) = Some(count);
                    }
                    Some((name, ..)) => {
                        return Err(format!(
                            "--{} is not an option of `project read`.\n{USAGE}",
                            name.chars().take(40).collect::<String>()
                        ));
                    }
                    None => words.push(arg),
                }
            }
            named(&words, 2, "Give the file's path inside the project.")?;
            Ok(Command::Ask(
                Ask::Read {
                    project: words[0].clone(),
                    path: words[1].clone(),
                    offset,
                    limit,
                },
                PATIENCE,
            ))
        }
        "write" => {
            let words: Vec<&String> = rest.iter().collect();
            named(&words, 2, "Give the file's path inside the project.")?;
            if words.iter().any(|word| word.starts_with("--")) {
                return Err(format!("`project write` has no options.\n{USAGE}"));
            }
            Ok(Command::Ask(
                Ask::Write {
                    project: words[0].clone(),
                    path: words[1].clone(),
                    text: stdin()?,
                },
                PATIENCE,
            ))
        }
        "edit" => {
            // The texts are taken as they come, also when one starts with dashes.
            let (mut words, mut edits, mut old) = (Vec::new(), Vec::new(), None::<String>);
            let mut rest = rest.iter();
            while let Some(arg) = rest.next() {
                match (arg.as_str(), old.is_some()) {
                    ("--old", false) => {
                        old = Some(rest.next().ok_or("--old needs a text.")?.clone());
                    }
                    ("--new", true) => {
                        let new = rest.next().ok_or("--new needs a text.")?.clone();
                        edits.push((old.take().unwrap_or_default(), new));
                    }
                    ("--old", true) => return Err("Give --new after each --old.".into()),
                    ("--new", false) => return Err("Give --old before each --new.".into()),
                    (other, _) if other.starts_with("--") => {
                        return Err(format!(
                            "{} is not an option of `project edit`.\n{USAGE}",
                            other.chars().take(40).collect::<String>()
                        ));
                    }
                    _ => words.push(arg),
                }
            }
            if old.is_some() {
                return Err("Give --new after each --old.".into());
            }
            named(&words, 2, "Give the file's path inside the project.")?;
            if edits.is_empty() {
                return Err(format!(
                    "Say what to replace: --old TEXT --new TEXT.\n{USAGE}"
                ));
            }
            Ok(Command::Ask(
                Ask::Edit {
                    project: words[0].clone(),
                    path: words[1].clone(),
                    edits,
                },
                PATIENCE,
            ))
        }
        other => Err(format!(
            "Unknown project command {:?}.\n{USAGE}",
            other.chars().take(40).collect::<String>()
        )),
    }
}

/// The file content on standard input: text, and no more than a write carries.
fn content() -> Result<String, String> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .lock()
        .take(WRITE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "Could not read the content on standard input.")?;
    if bytes.len() > WRITE_BYTES {
        return Err(WRITE_SHAPE.into());
    }
    String::from_utf8(bytes)
        .map_err(|_| "`project write` takes text (UTF-8). Copy other files on the machine itself with `project run`.".into())
}

pub(crate) fn run() -> ! {
    let args: Result<Vec<String>, _> = std::env::args_os()
        .skip(2)
        .map(|arg| arg.into_string())
        .collect();
    let command = args
        .map_err(|_| "Use UTF-8 text for project commands.".to_owned())
        .and_then(|args| parse(&args, content));
    let (ask, patience) = match command {
        Ok(Command::Help) => {
            println!("{USAGE}");
            std::process::exit(0)
        }
        Ok(Command::Ask(ask, patience)) => (ask, patience),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(FAILED)
        }
    };
    match road::ask(Action::Project(ask), patience) {
        Ok(said) => {
            let mut out = std::io::stdout().lock();
            let _ = out.write_all(said.text.as_bytes());
            if !said.text.is_empty() && !said.text.ends_with('\n') {
                let _ = out.write_all(b"\n");
            }
            let _ = out.flush();
            if let Some(note) = said.stderr {
                eprintln!("{note}");
            }
            std::process::exit(said.exit.unwrap_or(0))
        }
        Err(error) => {
            eprintln!("{}", worded(error));
            std::process::exit(FAILED)
        }
    }
}

/// The road to the workspace speaks of helpers when it fails (`helpers::cli`). The same failures, said for
/// projects. A refusal from a sandbox comes with a second line, which stays.
fn worded(error: String) -> String {
    let error = error.replacen(crate::helpers::UNREGISTERED, super::NOT_AN_AGENT, 1);
    match error.as_str() {
        road::OFFLINE => OFFLINE.into(),
        road::BLOCKED => BLOCKED.into(),
        road::SILENT => SILENT.into(),
        road::TOO_LONG => WRITE_SHAPE.into(),
        _ => error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(words: &[&str]) -> Result<Command, String> {
        let args: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
        parse(&args, || Ok("from stdin\n".into()))
    }

    fn run_of(words: &[&str]) -> (String, Vec<String>, Option<u64>, Duration) {
        match parsed(words) {
            Ok(Command::Ask(
                Ask::Run {
                    project,
                    command,
                    seconds,
                },
                patience,
            )) => (project, command, seconds, patience),
            other => panic!("{words:?}: {other:?}"),
        }
    }

    #[test]
    fn a_run_takes_its_own_options_only_before_the_command() {
        let (project, command, seconds, patience) = run_of(&[
            "run",
            "shop",
            "--",
            "git",
            "log",
            "--oneline",
            "--timeout",
            "3",
        ]);
        assert_eq!(project, "shop");
        assert_eq!(command, ["git", "log", "--oneline", "--timeout", "3"]);
        assert_eq!(seconds, None);
        assert_eq!(
            patience,
            Duration::from_secs(super::super::RUN_SECONDS) + MARGIN
        );

        let (_, command, seconds, patience) = run_of(&[
            "run",
            "--timeout",
            "300",
            "shop",
            "--",
            "cd src && make test",
        ]);
        assert_eq!(command, ["cd src && make test"]);
        assert_eq!(seconds, Some(300));
        assert_eq!(patience, Duration::from_secs(300) + MARGIN);

        // The workspace holds the time to Core's ceiling; the command waits no longer than that either.
        let (_, _, seconds, patience) = run_of(&["run", "shop", "--timeout=99999", "--", "make"]);
        assert_eq!(seconds, Some(99_999));
        assert_eq!(patience, Duration::from_secs(600) + MARGIN);

        // A forgotten `--` still runs what follows the name, dashes and all.
        let (_, command, ..) = run_of(&["run", "shop", "ls", "-la", "--color=never"]);
        assert_eq!(command, ["ls", "-la", "--color=never"]);
        let (_, command, ..) = run_of(&["run", "shop", "--", "--", "x"]);
        assert_eq!(command, ["--", "x"]);

        for refused in [
            vec!["run"],
            vec!["run", "shop"],
            vec!["run", "shop", "--"],
            vec!["run", "--", "ls"],
            vec!["run", "--on", "box", "shop", "--", "ls"],
            vec!["run", "--cwd=/", "shop", "--", "ls"],
            vec!["run", "shop", "--timeout", "soon", "--", "ls"],
            vec!["run", "shop", "--timeout", "0", "--", "ls"],
            vec!["run", "shop", "--timeout"],
        ] {
            assert!(parsed(&refused).is_err(), "{refused:?}");
        }
    }

    #[test]
    fn reads_the_file_commands() {
        assert_eq!(parsed(&["list"]), Ok(Command::Ask(Ask::List, PATIENCE)));
        assert_eq!(
            parsed(&["read", "shop", "src/main.rs"]),
            Ok(Command::Ask(
                Ask::Read {
                    project: "shop".into(),
                    path: "src/main.rs".into(),
                    offset: None,
                    limit: None
                },
                PATIENCE
            ))
        );
        assert_eq!(
            parsed(&["read", "--offset=201", "shop", "a.txt", "--limit", "50"]),
            Ok(Command::Ask(
                Ask::Read {
                    project: "shop".into(),
                    path: "a.txt".into(),
                    offset: Some(201),
                    limit: Some(50)
                },
                PATIENCE
            ))
        );
        assert_eq!(
            parsed(&["write", "shop", "notes/a.md"]),
            Ok(Command::Ask(
                Ask::Write {
                    project: "shop".into(),
                    path: "notes/a.md".into(),
                    text: "from stdin\n".into()
                },
                PATIENCE
            ))
        );
        assert_eq!(
            parsed(&[
                "edit",
                "shop",
                "--old",
                "--port 3000",
                "--new",
                "--port 4000",
                "run.sh",
                "--old",
                "a\nb",
                "--new",
                ""
            ]),
            Ok(Command::Ask(
                Ask::Edit {
                    project: "shop".into(),
                    path: "run.sh".into(),
                    edits: vec![
                        ("--port 3000".into(), "--port 4000".into()),
                        ("a\nb".into(), String::new())
                    ]
                },
                PATIENCE
            ))
        );
        assert_eq!(parsed(&[]), Ok(Command::Help));
        assert_eq!(parsed(&["--help"]), Ok(Command::Help));
        for refused in [
            vec!["list", "all"],
            vec!["read"],
            vec!["read", "shop"],
            vec!["read", "shop", "a", "b"],
            vec!["read", "shop", "a", "--offset", "0"],
            vec!["read", "shop", "a", "--lines", "3"],
            vec!["read", "shop", "a", "--on", "box"],
            vec!["write", "shop"],
            vec!["write", "shop", "a", "--append"],
            vec!["edit", "shop", "a"],
            vec!["edit", "shop", "a", "--old", "x"],
            vec!["edit", "shop", "a", "--new", "y"],
            vec![
                "edit", "shop", "a", "--old", "x", "--old", "y", "--new", "z",
            ],
            vec!["edit", "shop", "--old", "x", "--new", "y"],
            vec!["edit", "shop", "a", "--all", "--old", "x", "--new", "y"],
            vec!["connect", "box"],
            vec!["add", "shop", "box", "/srv"],
        ] {
            assert!(parsed(&refused).is_err(), "{refused:?}");
        }
    }

    #[test]
    fn failures_on_the_way_to_the_workspace_are_said_for_projects() {
        for said in [road::OFFLINE, road::BLOCKED, road::SILENT, road::TOO_LONG] {
            let worded = worded(said.into());
            assert!(
                !worded.contains("helper ") && !worded.contains("12 KB"),
                "{worded}"
            );
        }
        assert_eq!(
            worded(crate::helpers::UNREGISTERED.into()),
            super::super::NOT_AN_AGENT
        );
        // From a sandbox, a refusal carries a second line saying that it is the workspace's answer.
        let refused = worded(format!(
            "{}\nThis is the workspace's answer.",
            crate::helpers::UNREGISTERED
        ));
        assert_eq!(
            refused,
            format!(
                "{}\nThis is the workspace's answer.",
                super::super::NOT_AN_AGENT
            )
        );
        assert_eq!(
            worded("You have no project named \"x\".".into()),
            "You have no project named \"x\"."
        );
    }

    #[test]
    fn the_command_cannot_name_a_host_or_a_folder_outside_the_project() {
        // Nothing an agent types becomes a machine or a working folder: the request has no field for either.
        let (_, command, ..) = run_of(&["run", "shop", "--", "ls", "--on", "box"]);
        assert_eq!(command, ["ls", "--on", "box"]);
        let asked = serde_json::to_value(Action::Project(Ask::Run {
            project: "shop".into(),
            command,
            seconds: None,
        }))
        .unwrap();
        let mut fields: Vec<&str> = asked
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        fields.sort_unstable();
        assert_eq!(fields, ["command", "do", "op", "project", "seconds"]);
    }
}
