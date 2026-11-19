//! `swarmhub-herdr bot …`, `checkin …` and `promise …`, run by a bot's agent in its own terminal. Like `helper`
//! and `project`, a command only asks the running workspace and prints its answer: who may write to whom, what
//! is open and every limit are the workspace's to decide (`rules`, `plans`).

use super::plans::When;
use crate::helpers::{Action, cli as road};
use serde::{Deserialize, Serialize};
use std::time::Duration;

pub(crate) const USAGE: &str = "Bots (messages to the other bots of this server; the person can read them in both chats):
  swarmhub-herdr bot list                     who you can write to, and what is open
  swarmhub-herdr bot ask NAME TEXT            you need an answer; it comes later as a message to you
  swarmhub-herdr bot tell NAME TEXT           for its information; no answer comes
  swarmhub-herdr bot handoff NAME TEXT        it takes the work over and reports back when done
  swarmhub-herdr bot reply ID TEXT            answer an ask, or report the result of a hand-off you accepted
  swarmhub-herdr bot accept ID                take over the work of a hand-off
  swarmhub-herdr bot decline ID REASON        refuse an ask or a hand-off
  swarmhub-herdr bot job submit KEY -         queue a managed fixture job from JSON on stdin
  swarmhub-herdr bot job review -             record evidence or reserve a fix from JSON on stdin
  swarmhub-herdr bot job review status ID     inspect a review lineage
  swarmhub-herdr bot job list                 list your recent jobs
  swarmhub-herdr bot job status ID            show status and available result references
  swarmhub-herdr bot job cancel ID            record a cancellation request
  swarmhub-herdr bot job result ID REF        read a verified job result
  swarmhub-herdr bot completion inbox [ID]   recover your job completions by JOB:ATTEMPT
  swarmhub-herdr bot completion ack ID       acknowledge and return the durable next-step key
  swarmhub-herdr bot park file ID -         file an immutable manifest JSON as the current owner
  swarmhub-herdr bot park status ID         inspect your park and its receipt
  swarmhub-herdr bot park judge -           submit a delegated execute signature as JSON
  swarmhub-herdr bot park backstop -        submit a delegated auto_execute signature as JSON
      TEXT `-` reads standard input. Quote a NAME of several words.
Check-ins (the server brings you back to something, also with the app closed):
  swarmhub-herdr checkin in 30m WHAT          once; also: at 17:30
  swarmhub-herdr checkin every 2h WHAT        again and again; also: every day at 9:00, every weekday at 9:00
  swarmhub-herdr checkin ci PUBLIC_PR_URL WHAT   once, on a failed GitHub check
  swarmhub-herdr checkin list
  swarmhub-herdr checkin cancel ID
Promises (what you told the person you will do or report later):
  swarmhub-herdr promise add --by 30m WHAT    also: --by 17:30
  swarmhub-herdr promise done ID [NOTE]
  swarmhub-herdr promise list";

const OFFLINE: &str = "The SwarmHub workspace server is not running, so nothing was sent or planned. Tell the person what you wanted to do.";
const BLOCKED: &str = "A sandbox stopped this command from reaching the SwarmHub workspace, and it found no .swarmhub-helpers folder it may write to. Nothing was sent or planned. Run the command from the folder this agent was started in.";
const SILENT: &str = "The workspace did not answer in time. Run `swarmhub-herdr bot list` to see what happened before trying again.";
const TOO_LONG: &str = "That is too long. Use up to 4000 characters of plain text; put longer material in a file and name the file.";
pub(crate) const NOT_A_BOT: &str = "This terminal is not the agent of one of the person's bots, so it cannot write to bots, plan check-ins or record promises.";
const PATIENCE: Duration = Duration::from_secs(60);
const TEXT_BYTES: usize = 32 * 1024;

/// What a command asks the workspace.
#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, tag = "op", rename_all = "snake_case")]
pub(crate) enum Ask {
    List,
    CompletionInbox { id: Option<String> },
    CompletionAck { id: String },
    Park { command: Box<crate::parks::Command> },
    Job { command: Box<crate::jobs::Command> },
    JobReview { command: Box<crate::job_reviews::Command> },
    /// `kind` is `ask`, `tell` or `handoff`.
    Send {
        kind: String,
        to: String,
        text: String,
    },
    Reply {
        id: i64,
        text: String,
    },
    Accept {
        id: i64,
    },
    Decline {
        id: i64,
        reason: String,
    },
    Checkin {
        when: When,
        what: String,
    },
    Checkins,
    CancelCheckin {
        id: i64,
    },
    Promise {
        by: When,
        what: String,
    },
    PromiseDone {
        id: i64,
        note: Option<String>,
    },
    Promises,
}

#[derive(Debug, PartialEq, Eq)]
enum Command {
    Ask(Ask),
    Help,
}

/// "30m", "90s", "2h", "1d", "45min", "2hours": seconds.
fn duration(word: &str) -> Option<u64> {
    let word = word.to_ascii_lowercase();
    let digits = word.chars().take_while(char::is_ascii_digit).count();
    let count: u64 = word[..digits].parse().ok()?;
    let unit = match &word[digits..] {
        "s" | "sec" | "secs" | "second" | "seconds" => 1,
        "m" | "min" | "mins" | "minute" | "minutes" => 60,
        "h" | "hr" | "hrs" | "hour" | "hours" => 3_600,
        "d" | "day" | "days" => 86_400,
        _ => return None,
    };
    count
        .checked_mul(unit)
        .filter(|seconds| (1..=366 * 86_400).contains(seconds))
}

/// "17:30", "9:00", "9", "9am", "5pm": hour and minute.
fn clock(word: &str) -> Option<(u8, u8)> {
    let word = word.to_ascii_lowercase();
    let (time, half) = match (word.strip_suffix("am"), word.strip_suffix("pm")) {
        (Some(time), _) => (time, Some(false)),
        (_, Some(time)) => (time, Some(true)),
        _ => (word.as_str(), None),
    };
    let (hour, minute) = time.split_once(':').unwrap_or((time, "0"));
    if hour.is_empty() || hour.len() > 2 || minute.len() > 2 {
        return None;
    }
    let (mut hour, minute): (u8, u8) = (hour.parse().ok()?, minute.parse().ok()?);
    match half {
        Some(_) if !(1..=12).contains(&hour) => return None,
        Some(true) if hour < 12 => hour += 12,
        Some(false) if hour == 12 => hour = 0,
        _ => {}
    }
    (hour < 24 && minute < 60).then_some((hour, minute))
}

/// The words that say when, at the start of `words`, and how many of them there were.
fn when(words: &[&str]) -> Result<(When, usize), String> {
    const SHAPE: &str =
        "Say when: in 30m, at 17:30, every 2h, every day at 9:00 or every weekday at 9:00.";
    // "30 minutes" as two words is one duration.
    let span = |at: usize| -> Option<(u64, usize)> {
        let first = words.get(at)?;
        duration(first).map(|seconds| (seconds, 1)).or_else(|| {
            duration(&format!("{first}{}", words.get(at + 1)?)).map(|seconds| (seconds, 2))
        })
    };
    match words {
        ["ci", url, ..] => Ok((
            When::Ci {
                url: super::ci::pull_request(url)
                    .ok_or("Give a public GitHub pull request URL.")?,
            },
            2,
        )),
        ["in", ..] => {
            let (seconds, used) = span(1).ok_or(SHAPE)?;
            Ok((When::In { seconds }, 1 + used))
        }
        ["at", time, ..] => {
            let (hour, minute) = clock(time).ok_or(SHAPE)?;
            Ok((When::At { hour, minute }, 2))
        }
        ["every", days @ ("day" | "weekday"), "at", time, ..] => {
            let (hour, minute) = clock(time).ok_or(SHAPE)?;
            let weekdays = *days == "weekday";
            Ok((
                When::Daily {
                    hour,
                    minute,
                    weekdays,
                },
                4,
            ))
        }
        ["every", ..] => {
            let (seconds, used) = span(1).ok_or(SHAPE)?;
            Ok((When::Every { seconds }, 1 + used))
        }
        _ => Err(SHAPE.into()),
    }
}

fn id(word: Option<&&str>) -> Result<i64, String> {
    word.and_then(|word| word.trim_start_matches('#').parse::<i64>().ok())
        .filter(|id| *id > 0)
        .ok_or_else(|| "Give the number of the message, as in `bot reply 12 TEXT`.".to_owned())
}

/// The arguments after `bot`, `checkin` or `promise`. `stdin` supplies a text given as `-`.
pub(crate) fn job_submit(key: &str, input: &str) -> Result<Ask, String> {
    let input = serde_json::from_str(input).map_err(|_| "Use a managed fixture job JSON document.")?;
    Ok(Ask::Job { command: Box::new(crate::jobs::Command::Submit { key: key.into(), input }) })
}

fn parse(
    family: &str,
    args: &[String],
    stdin: impl FnOnce() -> Result<String, String>,
) -> Result<Command, String> {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let Some((verb, rest)) = words.split_first() else {
        return Ok(Command::Help);
    };
    if matches!(*verb, "--help" | "-h" | "help") {
        return Ok(Command::Help);
    }
    let text = |words: &[&str], what: &str| -> Result<String, String> {
        match words {
            [] => Err(format!("{what}\n{USAGE}")),
            ["-"] => stdin(),
            words => Ok(words.join(" ")),
        }
    };
    let alone = |most: usize| {
        if rest.len() > most {
            Err(format!("Too many words for this command.\n{USAGE}"))
        } else {
            Ok(())
        }
    };
    let ask = match (family, *verb) {
        ("bot", "list") => {
            alone(0)?;
            Ask::List
        }
        ("bot", "job") => {
            use crate::jobs::Command;
            let command = match rest {
                ["submit", key, "-"] => return Ok(self::Command::Ask(job_submit(key, &text(&["-"], "")?)?)),
                ["--help" | "-h" | "help"] => return Ok(self::Command::Help),
                ["review", "-"] => return Ok(self::Command::Ask(Ask::JobReview {
                    command: serde_json::from_str(&text(&["-"], "")?).map_err(|_| "Use a review command JSON document.")?,
                })),
                ["review", "status", lineage] => return Ok(self::Command::Ask(Ask::JobReview {
                    command: Box::new(crate::job_reviews::Command::Status { lineage: (*lineage).into() }),
                })),
                ["list"] => Command::List,
                ["status", id] => Command::Status { id: (*id).into() },
                ["cancel", id] => Command::Cancel { id: (*id).into() },
                ["result", id, reference] => Command::Result { id: (*id).into(), reference: (*reference).into() },
                _ => return Err("Use bot job submit KEY -, list, status ID, cancel ID, result ID REF, review -, or review status ID.".into()),
            };
            Ask::Job { command: Box::new(command) }
        }
        ("bot", "completion") => {
            let event_id = |id: &str| {
                super::completions::valid_id(id)
                    .then(|| id.to_owned())
                    .ok_or_else(|| "Use a completion ID in JOB:ATTEMPT form.".to_owned())
            };
            match rest {
                ["inbox"] => Ask::CompletionInbox { id: None },
                ["inbox", id] => Ask::CompletionInbox { id: Some(event_id(id)?) },
                ["ack", id] => Ask::CompletionAck { id: event_id(id)? },
                _ => return Err("Use bot completion inbox [ID] or bot completion ack ID.".into()),
            }
        }
        ("bot", "park") => {
            use crate::{fleet_policy::principals::{Signed, Target}, parks::{Command, ParkRef}};
            let command = match rest {
                ["file", id, "-"] => Command::File {
                    id: (*id).into(),
                    manifest: serde_json::from_str(&text(&["-"], "")?).map_err(|_| "Use a park manifest JSON.")?,
                },
                ["status", id] => Command::Status { id: (*id).into() },
                [verb @ ("judge" | "backstop"), "-"] => {
                    let signed: Signed = serde_json::from_str(&text(&["-"], "")?).map_err(|_| "Use a signed park decision JSON.")?;
                    let Target::Park { park, .. } = &signed.envelope.target else {
                        return Err("The signed decision must name a park.".into());
                    };
                    let park = ParkRef { id: park.id.clone(), manifest_digest: park.manifest_digest.clone() };
                    if *verb == "judge" { Command::Judge { park, signed } }
                    else { Command::Backstop { park, signed } }
                }
                _ => return Err("Use bot park file ID -, status ID, judge -, or backstop -.".into()),
            };
            Ask::Park { command: Box::new(command) }
        }
        ("bot", kind @ ("ask" | "tell" | "handoff" | "hand-off")) => {
            let to = rest
                .first()
                .ok_or_else(|| format!("Name the bot to write to.\n{USAGE}"))?;
            Ask::Send {
                kind: kind.replace('-', ""),
                to: (*to).to_owned(),
                text: text(&rest[1..], "Write what to send.")?,
            }
        }
        ("bot", "reply" | "report" | "answer") => Ask::Reply {
            id: id(rest.first())?,
            text: text(&rest[1..], "Write the answer.")?,
        },
        ("bot", "accept") => {
            alone(1)?;
            Ask::Accept {
                id: id(rest.first())?,
            }
        }
        ("bot", "decline" | "refuse") => Ask::Decline {
            id: id(rest.first())?,
            reason: text(&rest[1..], "Say why you decline.")?,
        },
        ("checkin", "list") => {
            alone(0)?;
            Ask::Checkins
        }
        ("checkin", "cancel") => {
            alone(1)?;
            Ask::CancelCheckin {
                id: id(rest.first())?,
            }
        }
        ("checkin", "ci" | "in" | "at" | "every") => {
            let (when, used) = when(&words)?;
            Ask::Checkin {
                when,
                what: text(&words[used..], "Say what to come back to.")?,
            }
        }
        ("promise", "list") => {
            alone(0)?;
            Ask::Promises
        }
        ("promise", "done") => Ask::PromiseDone {
            id: id(rest.first())?,
            note: (rest.len() > 1).then(|| rest[1..].join(" ")),
        },
        ("promise", "add") => {
            const BY: &str = "Say by when: promise add --by 30m WHAT, or --by 17:30.";
            // `--by 30m`, `--by=17:30`, and `--by 30 minutes`.
            let at = rest
                .iter()
                .position(|word| *word == "--by" || word.starts_with("--by="))
                .ok_or(BY)?;
            let (mut value, mut used): (Vec<&str>, usize) = match rest[at].strip_prefix("--by=") {
                Some(value) => (vec![value], 1),
                None => (vec![*rest.get(at + 1).ok_or(BY)?], 2),
            };
            if value[0].bytes().all(|byte| byte.is_ascii_digit())
                && let Some(unit) = rest.get(at + used)
                && duration(&format!("{}{unit}", value[0])).is_some()
            {
                value.push(*unit);
                used += 1;
            }
            let joined = value.concat();
            let by = duration(&joined)
                .map(|seconds| When::In { seconds })
                .or_else(|| clock(&joined).map(|(hour, minute)| When::At { hour, minute }))
                .ok_or(BY)?;
            let what: Vec<&str> = rest[..at]
                .iter()
                .chain(&rest[at + used..])
                .copied()
                .collect();
            Ask::Promise {
                by,
                what: text(&what, "Say what you promise.")?,
            }
        }
        (_, other) => {
            return Err(format!(
                "Unknown {family} command {:?}.\n{USAGE}",
                other.chars().take(40).collect::<String>()
            ));
        }
    };
    Ok(Command::Ask(ask))
}

/// The road to the workspace speaks of helpers when it fails (`helpers::cli`). The same failures, said for bots.
fn worded(error: String) -> String {
    let error = error.replacen(crate::helpers::UNREGISTERED, NOT_A_BOT, 1);
    match error.as_str() {
        road::OFFLINE => OFFLINE.into(),
        road::BLOCKED => BLOCKED.into(),
        road::SILENT => SILENT.into(),
        road::TOO_LONG => TOO_LONG.into(),
        _ => error,
    }
}

/// `family` is `bot`, `checkin` or `promise`.
pub(crate) fn run(family: &str) -> ! {
    let args: Result<Vec<String>, _> = std::env::args_os()
        .skip(2)
        .map(|arg| arg.into_string())
        .collect();
    let command = args
        .map_err(|_| "Use UTF-8 text for this command.".to_owned())
        .and_then(|args| {
            parse(family, &args, || {
                crate::agent::read_input(TEXT_BYTES)
                    .map_err(|_| "Could not read the text on standard input.".into())
            })
        });
    let ask = match command {
        Ok(Command::Help) => {
            println!("{USAGE}");
            std::process::exit(0)
        }
        Ok(Command::Ask(ask)) => ask,
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(2)
        }
    };
    match road::ask(Action::Bot(ask), PATIENCE) {
        Ok(said) => {
            println!("{}", said.text);
            std::process::exit(0)
        }
        Err(error) => {
            eprintln!("{}", worded(error));
            std::process::exit(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(family: &str, line: &str) -> Result<Command, String> {
        let args: Vec<String> = line.split(' ').map(str::to_owned).collect();
        parse(family, &args, || Ok("from stdin".into()))
    }

    fn ask(family: &str, line: &str) -> Ask {
        match parsed(family, line) {
            Ok(Command::Ask(ask)) => ask,
            other => panic!("{line}: {other:?}"),
        }
    }

    #[test]
    fn gapplan_03_unit_reads_owner_completion_commands() {
        assert_eq!(ask("bot", "completion inbox"), Ask::CompletionInbox { id: None });
        assert_eq!(ask("bot", "completion inbox job-abcd:2"),
            Ask::CompletionInbox { id: Some("job-abcd:2".into()) });
        assert_eq!(ask("bot", "completion ack job-abcd:2"),
            Ask::CompletionAck { id: "job-abcd:2".into() });
        for line in ["completion ack", "completion ack job:0", "completion ack ../job:1",
                     "completion inbox job:1 extra"] {
            assert!(parsed("bot", line).is_err(), "{line}");
        }
    }

    #[test]
    fn reads_the_messages_between_bots() {
        assert_eq!(ask("bot", "list"), Ask::List);
        assert_eq!(
            ask("bot", "ask Infra Which port does staging use?"),
            Ask::Send {
                kind: "ask".into(),
                to: "Infra".into(),
                text: "Which port does staging use?".into()
            }
        );
        // A name of several words is one argument, as a shell passes a quoted one.
        let args = ["tell", "Infra Bot", "Standup moved."].map(str::to_owned);
        assert_eq!(
            parse("bot", &args, || unreachable!()),
            Ok(Command::Ask(Ask::Send {
                kind: "tell".into(),
                to: "Infra Bot".into(),
                text: "Standup moved.".into()
            }))
        );
        for line in ["handoff Infra -", "hand-off Infra -"] {
            assert_eq!(
                ask("bot", line),
                Ask::Send {
                    kind: "handoff".into(),
                    to: "Infra".into(),
                    text: "from stdin".into()
                }
            );
        }
        assert_eq!(
            ask("bot", "reply #12 It is 5432."),
            Ask::Reply {
                id: 12,
                text: "It is 5432.".into()
            }
        );
        assert_eq!(ask("bot", "accept 14"), Ask::Accept { id: 14 });
        assert_eq!(
            ask("bot", "decline 14 Not my area."),
            Ask::Decline {
                id: 14,
                reason: "Not my area.".into()
            }
        );
        for refused in [
            "ask",
            "ask Infra",
            "reply",
            "reply twelve Yes",
            "reply 12",
            "accept",
            "accept 14 gladly",
            "decline 14",
            "list all",
            "message Infra Hi",
        ] {
            assert!(parsed("bot", refused).is_err(), "{refused}");
        }
        assert_eq!(parse("bot", &[], || unreachable!()), Ok(Command::Help));
        assert_eq!(parsed("bot", "--help"), Ok(Command::Help));
        // The command has no place for a sender: who asks is the launch that runs it.
        assert!(
            serde_json::from_str::<Ask>(
                r#"{"op":"send","kind":"ask","to":"A","text":"x","from":"B"}"#
            )
            .is_err()
        );
    }

    #[test]
    fn reads_when_a_check_in_fires() {
        let checkin = |line: &str| match ask("checkin", line) {
            Ask::Checkin { when, what } => (when, what),
            other => panic!("{line}: {other:?}"),
        };
        assert_eq!(
            checkin("in 30m Check the deploy."),
            (When::In { seconds: 1_800 }, "Check the deploy.".into())
        );
        assert_eq!(
            checkin("in 30 minutes Check the deploy."),
            (When::In { seconds: 1_800 }, "Check the deploy.".into())
        );
        assert_eq!(
            checkin("at 17:30 Look at the queue"),
            (
                When::At {
                    hour: 17,
                    minute: 30
                },
                "Look at the queue".into()
            )
        );
        assert_eq!(
            checkin("every 2h Look at the queue"),
            (When::Every { seconds: 7_200 }, "Look at the queue".into())
        );
        assert_eq!(
            checkin("every weekday at 9 Read the overnight alerts"),
            (
                When::Daily {
                    hour: 9,
                    minute: 0,
                    weekdays: true
                },
                "Read the overnight alerts".into()
            )
        );
        assert_eq!(
            checkin("every day at 9:15pm -"),
            (
                When::Daily {
                    hour: 21,
                    minute: 15,
                    weekdays: false
                },
                "from stdin".into()
            )
        );
        assert_eq!(ask("checkin", "list"), Ask::Checkins);
        assert_eq!(ask("checkin", "cancel #3"), Ask::CancelCheckin { id: 3 });
        for refused in [
            "in soon Check",
            "in 30m",
            "at 25:00 Check",
            "at noon Check",
            "every Check it",
            "every weekday Check",
            "cancel",
            "tomorrow Check",
        ] {
            assert!(parsed("checkin", refused).is_err(), "{refused}");
        }
        assert_eq!(
            [
                duration("90s"),
                duration("2hours"),
                duration("1d"),
                duration("0m"),
                duration("m")
            ],
            [Some(90), Some(7_200), Some(86_400), None, None]
        );
        assert_eq!(
            [
                clock("9"),
                clock("12am"),
                clock("12pm"),
                clock("5pm"),
                clock("23:59"),
                clock("24:00"),
                clock("13pm"),
                clock("9:60")
            ],
            [
                Some((9, 0)),
                Some((0, 0)),
                Some((12, 0)),
                Some((17, 0)),
                Some((23, 59)),
                None,
                None,
                None
            ]
        );
    }

    #[test]
    fn reads_promises() {
        assert_eq!(
            ask("promise", "add --by 30m Send the weekly report"),
            Ask::Promise {
                by: When::In { seconds: 1_800 },
                what: "Send the weekly report".into()
            }
        );
        assert_eq!(
            ask("promise", "add Send the report --by=17:30"),
            Ask::Promise {
                by: When::At {
                    hour: 17,
                    minute: 30
                },
                what: "Send the report".into()
            }
        );
        assert_eq!(
            ask("promise", "add --by 2 hours Send the report"),
            Ask::Promise {
                by: When::In { seconds: 7_200 },
                what: "Send the report".into()
            }
        );
        assert_eq!(
            ask("promise", "done 3"),
            Ask::PromiseDone { id: 3, note: None }
        );
        assert_eq!(
            ask("promise", "done 3 Sent to the list."),
            Ask::PromiseDone {
                id: 3,
                note: Some("Sent to the list.".into())
            }
        );
        assert_eq!(ask("promise", "list"), Ask::Promises);
        for refused in [
            "add Send it",
            "add --by soon Send it",
            "add --by 30m",
            "done",
            "keep 3",
        ] {
            assert!(parsed("promise", refused).is_err(), "{refused}");
        }
    }

    #[test]
    fn says_what_went_wrong_in_its_own_words() {
        assert_eq!(worded(road::OFFLINE.into()), OFFLINE);
        assert_eq!(worded(crate::helpers::UNREGISTERED.into()), NOT_A_BOT);
        assert_eq!(
            worded("A refusal of the workspace.".into()),
            "A refusal of the workspace."
        );
    }
}
