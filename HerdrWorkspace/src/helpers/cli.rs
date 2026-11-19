//! `swarmhub-herdr helper …`, run by an agent in its own terminal. It asks the running workspace and prints the
//! answer as plain text. It decides nothing itself: no policy, no limit and no launch happens in this process.

use super::{Action, REPLY_LIMIT, REQUEST_LIMIT, Reply, Request, socket_path, spool};
use std::{
    io::{BufRead, BufReader, Read, Write},
    os::unix::net::UnixStream,
    path::Path,
    time::{Duration, Instant},
};

pub(crate) const USAGE: &str = "Helpers (another agent for one task; the workspace picks its model from the difficulty):
  swarmhub-herdr helper start --difficulty easy|medium|hard [--name NAME] [--here] TASK
      TASK `-` reads standard input. --here starts it in this folder instead of the workspace's agent folder.
  swarmhub-herdr helper managed KEY -           queue an enrolled fixture job from JSON on stdin
  swarmhub-herdr helper list
  swarmhub-herdr helper wait NAME [--seconds N]   wait for its answer, then print it (default 100 seconds)
  swarmhub-herdr helper read NAME [--lines N]     its latest answer, or the last N lines of its screen
  swarmhub-herdr helper send NAME TEXT            give it a follow-up
  swarmhub-herdr helper stop NAME                 end it when you no longer need it";

pub(crate) const OFFLINE: &str = "The SwarmHub workspace server is not running, so helpers are unavailable. Nothing was started or changed.";
pub(crate) const BLOCKED: &str = "A sandbox stopped this command from reaching the SwarmHub workspace, and it found no .swarmhub-helpers folder it may write to. Nothing was started or changed. Run the command from the folder this agent was started in.";
pub(crate) const SILENT: &str = "The workspace did not answer in time. Run `swarmhub-herdr helper list` to see what happened before trying again.";
pub(crate) const TOO_LONG: &str = "That is too long. Use up to 12 KB of plain text; put longer material in a file and name the file.";
const ANSWERED: &str = "This is the workspace's answer, not a sandbox failure: running the command outside the sandbox would give the same answer.";
/// Starting an agent can take more than a minute on a busy machine.
const PATIENCE: Duration = Duration::from_secs(170);
const WAIT_SECONDS: u64 = 100;
const MAX_WAIT_SECONDS: u64 = 590;
const POLL: Duration = Duration::from_secs(2);

#[derive(Debug, PartialEq, Eq)]
enum Command {
    Call(Action),
    Wait { name: String, seconds: u64 },
    Help,
}

/// The arguments after `helper`. `cwd` is where the command runs, for `--here`; `stdin` supplies a task given as `-`.
fn parse(
    args: &[String],
    cwd: Option<String>,
    stdin: impl FnOnce() -> Result<String, String>,
) -> Result<Command, String> {
    let Some((verb, rest)) = args.split_first() else {
        return Ok(Command::Help);
    };
    if verb == "managed" {
        let [key, dash] = rest else { return Err("Use helper managed KEY -.".into()) };
        if dash != "-" {
            return Err("Use helper managed KEY -.".into());
        }
        return Ok(Command::Call(Action::Bot(crate::bots::cli::job_submit(key, &stdin()?)?)));
    }
    let mut words = Vec::new();
    let mut options: Vec<(&str, String)> = Vec::new();
    let mut here = false;
    let mut rest = rest.iter();
    while let Some(arg) = rest.next() {
        if arg == "--" {
            words.extend(rest.by_ref().map(String::as_str));
        } else if arg == "--here" && verb == "start" && !here {
            here = true;
        } else if let Some(option) = arg.strip_prefix("--") {
            let (name, value) = match option.split_once('=') {
                Some((name, value)) => (name, value.to_owned()),
                None => (
                    option,
                    rest.next()
                        .ok_or_else(|| format!("--{option} needs a value.\n{USAGE}"))?
                        .clone(),
                ),
            };
            if options.iter().any(|(seen, _)| *seen == name) {
                return Err(format!("--{name} was given twice."));
            }
            options.push((name, value));
        } else {
            words.push(arg.as_str());
        }
    }
    let mut option = |name: &str| {
        options
            .iter()
            .position(|(seen, _)| *seen == name)
            .map(|index| options.swap_remove(index).1)
    };
    let number = |name: &str, value: Option<String>| {
        value
            .map(|value| {
                value
                    .parse::<u64>()
                    .ok()
                    .filter(|count| *count > 0)
                    .ok_or_else(|| format!("--{name} takes a whole number above zero."))
            })
            .transpose()
    };
    let name = |words: &[&str]| {
        words
            .first()
            .map(|name| (*name).to_owned())
            .ok_or_else(|| format!("Name the helper.\n{USAGE}"))
    };
    let alone = |words: &[&str], most: usize| {
        if words.len() > most {
            Err(format!("Too many words for this command.\n{USAGE}"))
        } else {
            Ok(())
        }
    };
    let command = match verb.as_str() {
        "--help" | "-h" | "help" => return Ok(Command::Help),
        "start" => {
            let difficulty = option("difficulty").ok_or(
                "Choose how hard the task is: --difficulty easy|medium|hard. The workspace picks the model.",
            )?;
            let helper = option("name");
            let task = match words.as_slice() {
                [] => return Err(format!("Give the helper a task.\n{USAGE}")),
                ["-"] => stdin()?,
                words => words.join(" "),
            };
            let cwd = match (here, cwd) {
                (false, _) => None,
                (true, Some(cwd)) => Some(cwd),
                (true, None) => return Err("This folder cannot be used. Leave out --here.".into()),
            };
            Command::Call(Action::Start {
                difficulty,
                name: helper,
                task,
                cwd,
            })
        }
        "list" => {
            alone(&words, 0)?;
            Command::Call(Action::List)
        }
        "read" => {
            alone(&words, 1)?;
            Command::Call(Action::Read {
                name: name(&words)?,
                lines: number("lines", option("lines"))?.map(|lines| lines.min(10_000) as usize),
            })
        }
        "wait" => {
            alone(&words, 1)?;
            Command::Wait {
                name: name(&words)?,
                seconds: number("seconds", option("seconds"))?
                    .unwrap_or(WAIT_SECONDS)
                    .min(MAX_WAIT_SECONDS),
            }
        }
        "send" => {
            let helper = name(&words)?;
            let text = match &words[1..] {
                [] => return Err(format!("Write what to tell the helper.\n{USAGE}")),
                ["-"] => stdin()?,
                words => words.join(" "),
            };
            Command::Call(Action::Send { name: helper, text })
        }
        "stop" => {
            alone(&words, 1)?;
            Command::Call(Action::Stop {
                name: name(&words)?,
            })
        }
        other => {
            return Err(format!(
                "Unknown helper command {:?}.\n{USAGE}",
                other.chars().take(40).collect::<String>()
            ));
        }
    };
    match options.first() {
        Some((unknown, _)) => Err(format!(
            "--{} is not an option of `helper {verb}`. The model and template cannot be chosen here; only the difficulty can.\n{USAGE}",
            unknown.chars().take(40).collect::<String>()
        )),
        None => Ok(command),
    }
}

fn call(journal: &Path, launch: &str, action: Action) -> Result<Reply, String> {
    call_within(journal, launch, action, PATIENCE)
}

/// What the workspace answered a `swarmhub-herdr project …` command.
pub(crate) struct Said {
    pub(crate) text: String,
    pub(crate) stderr: Option<String>,
    pub(crate) exit: Option<i32>,
}

/// Asks the running workspace for this agent session and waits up to `patience` for the answer. An error is the
/// workspace's refusal or one of `OFFLINE`, `BLOCKED` and `SILENT`.
pub(crate) fn ask(action: Action, patience: Duration) -> Result<Said, String> {
    let (journal, launch) = crate::agent::session().map_err(|_| super::UNREGISTERED)?;
    let reply = call_within(&journal, &launch, action, patience)?;
    Ok(Said {
        text: reply.text,
        stderr: reply.stderr,
        exit: reply.exit,
    })
}

fn call_within(
    journal: &Path,
    launch: &str,
    action: Action,
    patience: Duration,
) -> Result<Reply, String> {
    let request = Request {
        launch: launch.to_owned(),
        action,
    };
    let mut bytes = serde_json::to_vec(&request).map_err(|_| SILENT)?;
    bytes.push(b'\n');
    if bytes.len() > REQUEST_LIMIT {
        return Err(TOO_LONG.into());
    }
    let mut stream = match UnixStream::connect(socket_path(journal)) {
        Ok(stream) => stream,
        // Codex's sandbox refuses every connection a shell command makes, local sockets included. It still lets
        // the command write in the agent's folder, where the workspace looks for requests as files.
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            let cwd = std::env::current_dir().ok();
            let named = std::env::var_os(spool::ENV).map(Into::into);
            let reply = spool::find(named, cwd.as_deref())
                .ok_or(None)
                .and_then(|dir| spool::ask(&dir, launch, request.action, spool::PICKUP, patience))
                .map_err(|why| why.unwrap_or(BLOCKED))?;
            return match reply.error {
                // A Codex helper took a refusal for a sandbox failure and asked to run the command unsandboxed.
                Some(error) => Err(format!("{error}\n{ANSWERED}")),
                None => Ok(reply),
            };
        }
        Err(_) => return Err(OFFLINE.into()),
    };
    stream
        .set_read_timeout(Some(patience))
        .and_then(|()| stream.set_write_timeout(Some(Duration::from_secs(5))))
        .and_then(|()| stream.write_all(&bytes))
        .map_err(|_| SILENT)?;
    let mut line = Vec::new();
    BufReader::new(stream)
        .take(REPLY_LIMIT as u64)
        .read_until(b'\n', &mut line)
        .map_err(|_| SILENT)?;
    let reply: Reply = serde_json::from_slice(&line).map_err(|_| SILENT)?;
    match reply.error {
        Some(error) => Err(error),
        None => Ok(reply),
    }
}

fn perform() -> Result<String, String> {
    let args: Vec<String> = std::env::args_os()
        .skip(2)
        .map(|arg| arg.into_string())
        .collect::<Result<_, _>>()
        .map_err(|_| "Use UTF-8 text for helper commands.")?;
    let cwd = std::env::current_dir()
        .ok()
        .and_then(|path| path.into_os_string().into_string().ok());
    let command = parse(&args, cwd, || {
        crate::agent::read_input(REQUEST_LIMIT)
            .map_err(|_| "Could not read the text on standard input.".into())
    })?;
    if command == Command::Help {
        return Ok(USAGE.into());
    }
    let (journal, launch) = crate::agent::session().map_err(|_| super::UNREGISTERED)?;
    match command {
        Command::Help => Ok(USAGE.into()),
        Command::Call(action) => Ok(call(&journal, &launch, action)?.text),
        Command::Wait { name, seconds } => {
            let until = Instant::now() + Duration::from_secs(seconds);
            loop {
                let reply = call(
                    &journal,
                    &launch,
                    Action::Read {
                        name: name.clone(),
                        lines: None,
                    },
                )?;
                if !reply.working {
                    return Ok(reply.text);
                }
                if Instant::now() + POLL > until {
                    return Ok(format!(
                        "{}\nStill working after {seconds} seconds. Run the same command again to keep waiting.",
                        reply.text
                    ));
                }
                std::thread::sleep(POLL);
            }
        }
    }
}

pub(crate) fn run() -> ! {
    match perform() {
        Ok(text) => {
            println!("{text}");
            std::process::exit(0)
        }
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(line: &str) -> Result<Command, String> {
        let args: Vec<String> = line.split(' ').map(str::to_owned).collect();
        parse(&args, Some("/work".into()), || Ok("from stdin".into()))
    }

    fn start(difficulty: &str, name: Option<&str>, task: &str) -> Result<Command, String> {
        Ok(Command::Call(Action::Start {
            difficulty: difficulty.into(),
            name: name.map(str::to_owned),
            task: task.into(),
            cwd: None,
        }))
    }

    #[test]
    fn reads_a_start_with_its_options_in_any_place() {
        assert_eq!(
            parse(
                &["start", "--difficulty", "easy", "Count the files in src"].map(str::to_owned),
                Some("/work".into()),
                || unreachable!()
            ),
            start("easy", None, "Count the files in src")
        );
        // An unquoted task is joined; the workspace, not this command, judges the difficulty word.
        assert_eq!(
            parsed("start fix the test --name=tests --difficulty extreme"),
            start("extreme", Some("tests"), "fix the test")
        );
        assert_eq!(
            parsed("start --difficulty hard -- --verbose is ignored, why?"),
            start("hard", None, "--verbose is ignored, why?")
        );
        assert_eq!(
            parsed("start --difficulty medium -"),
            start("medium", None, "from stdin")
        );
        // Only --here sends the folder the command runs in.
        assert_eq!(
            parsed("start --here --difficulty easy x"),
            Ok(Command::Call(Action::Start {
                difficulty: "easy".into(),
                name: None,
                task: "x".into(),
                cwd: Some("/work".into()),
            }))
        );
        let args = ["start", "--difficulty", "easy", "--here", "x"].map(str::to_owned);
        assert!(parse(&args, None, || unreachable!()).is_err());
        assert!(parsed("start --here --here --difficulty easy x").is_err());
        assert!(parsed("start do it").unwrap_err().contains("--difficulty"));
        assert!(
            parsed("start --difficulty easy")
                .unwrap_err()
                .contains("task")
        );
        assert!(
            parsed("start --difficulty")
                .unwrap_err()
                .contains("needs a value")
        );
        assert!(
            parsed("start --difficulty easy --difficulty hard x")
                .unwrap_err()
                .contains("twice")
        );
    }

    #[test]
    fn has_no_way_to_name_a_model_or_a_template() {
        for line in [
            "start --difficulty easy --model opus do it",
            "start --difficulty easy --template mine do it",
            "start --difficulty=easy --cwd=/ do it",
            "list --all yes",
            "stop one --lines 3",
            "list --here x",
        ] {
            let refused = parsed(line).unwrap_err();
            assert!(refused.contains("is not an option"), "{line}: {refused}");
        }
    }

    #[test]
    fn reads_the_other_commands() {
        assert_eq!(parsed("list"), Ok(Command::Call(Action::List)));
        assert_eq!(
            parsed("read easy-1"),
            Ok(Command::Call(Action::Read {
                name: "easy-1".into(),
                lines: None
            }))
        );
        assert_eq!(
            parsed("read --lines 40 easy-1"),
            Ok(Command::Call(Action::Read {
                name: "easy-1".into(),
                lines: Some(40)
            }))
        );
        assert_eq!(
            parsed("wait easy-1"),
            Ok(Command::Wait {
                name: "easy-1".into(),
                seconds: WAIT_SECONDS
            })
        );
        assert_eq!(
            parsed("wait easy-1 --seconds 99999"),
            Ok(Command::Wait {
                name: "easy-1".into(),
                seconds: MAX_WAIT_SECONDS
            })
        );
        assert_eq!(
            parsed("send easy-1 also check the tests"),
            Ok(Command::Call(Action::Send {
                name: "easy-1".into(),
                text: "also check the tests".into()
            }))
        );
        assert_eq!(
            parsed("stop easy-1"),
            Ok(Command::Call(Action::Stop {
                name: "easy-1".into()
            }))
        );
        assert_eq!(parse(&[], None, || unreachable!()), Ok(Command::Help));
        assert_eq!(parsed("--help"), Ok(Command::Help));
        for line in [
            "read",
            "read a b",
            "read a --lines 0",
            "read a --lines many",
            "wait",
            "send easy-1",
            "stop",
            "list extra",
            "launch x",
        ] {
            assert!(parsed(line).is_err(), "{line}");
        }
    }

    #[test]
    fn fails_cleanly_when_the_workspace_is_not_running() {
        let scratch = tempfile::tempdir().unwrap();
        let journal = scratch.path().join("workspace.sqlite3");
        let key = "00112233445566778899aabbccddeeff";
        assert_eq!(call(&journal, key, Action::List).err().unwrap(), OFFLINE);
        // A socket file left behind by a workspace that stopped is the same case.
        drop(std::os::unix::net::UnixListener::bind(socket_path(&journal)).unwrap());
        assert_eq!(call(&journal, key, Action::List).err().unwrap(), OFFLINE);
        let long = Action::Send {
            name: "a".into(),
            text: "x".repeat(REQUEST_LIMIT),
        };
        assert!(
            call(&journal, key, long)
                .err()
                .unwrap()
                .contains("too long")
        );
    }
}
