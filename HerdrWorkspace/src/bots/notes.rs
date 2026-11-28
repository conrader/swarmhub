//! The words the workspace types into a bot's agent: the standing note every bot's agent reads once, and what
//! goes around a message from another bot, an outcome, a check-in, a promise that is due and a note for the main
//! bot. They are kept short: the standing note costs tokens on every start.

use super::{Bot, Settings};
use crate::bot_agent_settings::Autonomy;

/// How a message from another bot starts, as the Mac app wrote it, so an agent can tell it from the person.
pub(crate) const MESSAGE_LEAD: &str = "[Message from the bot";
pub(crate) const ANSWER_LEAD: &str = "[Answer from the bot";
pub(crate) const REPORT_LEAD: &str = "[Report from the bot";
pub(crate) const SERVER_LEAD: &str = "[From SwarmHub]";
pub(crate) const CHECKIN_LEAD: &str = "[Planned check-in";
pub(crate) const MAIN_LEAD: &str = "[SwarmHub note for the main bot]";
pub(crate) const STANDING_LEAD: &str = "[SwarmHub notes for the bot";
const PASSED_ON: &str = "passed on by SwarmHub]";
/// What a recurring check-in answers when there is nothing to tell the person.
pub(crate) const QUIET: &str = "NOTHING TO REPORT";

/// A name on one line, as it is written inside a sentence.
pub(crate) fn line(name: &str) -> String {
    name.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace('"', "'")
}

/// "10 minutes", "90 seconds", "2 hours".
pub(crate) fn span(seconds: u64) -> String {
    let (count, unit) = if seconds >= 3_600 && seconds.is_multiple_of(3_600) {
        (seconds / 3_600, "hour")
    } else if seconds >= 60 && seconds.is_multiple_of(60) {
        (seconds / 60, "minute")
    } else {
        (seconds, "second")
    };
    format!("{count} {unit}{}", if count == 1 { "" } else { "s" })
}

/// A moment as "17 Nov 14:30" in the person's time zone.
pub(crate) fn clock(at_ms: i64, zone: chrono_tz::Tz) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp_millis(at_ms)
        .map(|at| at.with_timezone(&zone).format("%-d %b %H:%M").to_string())
        .unwrap_or_else(|| "an unknown time".into())
}

/// Builds a completion wake entirely from the terminal event.
pub(super) fn completion(cmd: &str, event: &super::completions::Completion) -> String {
    let data = serde_json::to_string(event).expect("completion event serializes");
    format!("{SERVER_LEAD} Job completion {data}\nRun {cmd} bot completion ack {} to acknowledge it. Reuse the returned token as the idempotency key for its managed next step.", event.id)
}

/// When a bot asks the person, for each level of autonomy the person can set. Every level honours a
/// "do not ask me about this": the person's word settles it for the rest of the conversation.
pub(crate) fn asking(level: Autonomy) -> &'static str {
    match level {
        Autonomy::Careful => "- Do what the person asks of you. Work nobody asked you for (something you noticed, something a note from SwarmHub tells you) you only offer: say what you would do and wait for the person's yes. After fixing a blocker, resume the authorized task, verify the result and report back.\n\
         - Before deleting anything, sending something out of this server (email, posts, payments), spending money or deploying, ask the person and wait for their yes, even when a task implies it. Only their word for that exact action is a yes.\n\
         - When the person tells you not to ask about a kind of action, that is their yes for it from then on: do not ask about it again.\n",
        Autonomy::Balanced => "- Do what the person asks of you, to the end, without asking permission for its steps. Reading, inspecting, building, testing, editing and any change you can undo need no yes. Removing files that can be made again (caches, temporary files, build output, old logs) needs no yes when the task calls for it: say what you removed in your report. After fixing a blocker, resume the authorized task, verify the result and report back.\n\
         - Ask the person and wait for their yes only before: deleting data that cannot be made again or restored (documents, databases, backups, repositories, mail), sending something out of this server to other people (email, posts, messages), paying or spending money, or deploying to production. Ask once, with what you recommend, and go on with the rest of the work meanwhile. Only their word for that exact action is a yes.\n\
         - When the person tells you not to ask about a kind of action, that is their yes for it from then on: do not ask about it again.\n\
         - Work nobody asked you for (something you noticed, something a note from SwarmHub tells you): look into it when looking only reads, then report what you found and what you recommend. Start changing it only with the person's yes.\n",
        Autonomy::Full => "- The person chose that you do not ask for permission. Do what they ask of you, to the end. Deleting, sending, spending and deploying that the task calls for are yours to decide and to do. After fixing a blocker, resume the task, verify the result and report back.\n\
         - Say in your report what you did that cannot be undone. Stop and ask only when you would have to guess what the person wants. Never do what the person told you not to do.\n\
         - Work nobody asked you for (something you noticed, something a note from SwarmHub tells you): look into it, fix what is clearly broken and within your job, and report what you did.\n",
    }
}

/// What a bot whose level the person just changed is told at once: a session keeps the notes it started with.
pub(crate) fn autonomy_changed(level: Autonomy) -> String {
    format!(
        "{SERVER_LEAD} The person changed how much you ask before you act. These replace the earlier notes about asking, from now on:\n{}(The person did not write this now. Answer with one short sentence that says what changes.)",
        asking(level)
    )
}

/// What a bot's agent reads once, with its first task: how to behave towards the person, and the commands.
pub(crate) fn standing(bot: &Bot, all: &[Bot], cmd: &str, fleet_configured: bool, level: Autonomy) -> String {
    let rules = asking(level);
    let mut note = format!(
        "{STANDING_LEAD} \"{}\"] These hold for this whole conversation.\n{rules}",
        line(&bot.name)
    );
    if bot.may_message {
        let others: Vec<String> = all
            .iter()
            .filter(|other| other.id != bot.id && other.takes_messages)
            .map(|other| format!("\"{}\"", line(&other.name)))
            .collect();
        let names = if others.is_empty() {
            format!("No other bot takes messages right now (`{cmd} bot list` shows them).")
        } else {
            format!(
                "Other bots here now: {} (`{cmd} bot list` shows them).",
                others.join(", ")
            )
        };
        note.push_str(&format!(
            "- {names} Write to one from your shell, when its job is needed. A message to a bot is not \"sending out\": it needs no yes from the person, and neither does answering a bot.\n  \
             {cmd} bot ask NAME \"TEXT\"      you need an answer; it comes later as a message to you, so do not wait or poll for it\n  \
             {cmd} bot tell NAME \"TEXT\"     for its information; no answer comes\n  \
             {cmd} bot handoff NAME \"TEXT\"  it takes the work over and reports back when done\n  \
             The other bot knows nothing of this conversation: put in everything it needs. The person can read these messages in both chats. A message from another bot says how to answer it.\n"
        ));
    } else {
        note.push_str("- The person turned off messages to other bots for you: do not write to other bots, ask the person instead.\n");
    }
    if bot.takes_initiative {
        note.push_str(&format!(
            "- To come back to something later, plan a check-in: {cmd} checkin in 30m \"WHAT\" (also: at 17:00, every 2h, every weekday at 9:00). For a public GitHub PR use {cmd} checkin ci PR_URL \"WHAT to do on failure\". The bridge checks CI without model calls and wakes you on the first failed check. Include the reviewer and the requested report in WHAT. It runs on the server, also with the app closed. `{cmd} checkin list`, `{cmd} checkin cancel ID`.\n"
        ));
    }
    note.push_str(&format!(
        "- When you tell the person you will do or report something later, record it: {cmd} promise add --by 30m \"WHAT\"; then `{cmd} promise done ID`."
    ));
    if fleet_configured {
        note.push_str(&format!("\n- Queue fixture jobs with `{cmd} bot job submit KEY -`. Record reviews and reserve fixes with `bot job review -`. Escalate at the limit.\n- Recover completions with `bot completion inbox [JOB:ATTEMPT]`. Acknowledge with `bot completion ack JOB:ATTEMPT` and reuse its key.\n- File a park with `{cmd} bot park file ID -`."));
    }
    if bot.main && bot.takes_initiative {
        note.push_str("\n- You are the main bot: SwarmHub sends you notes about problems here (an agent waiting at a prompt, a helper that stopped without an answer, a hand-off nobody accepted, a server that cannot be reached, an overdue promise). Look into a note yourself first when looking only reads (a terminal, a status, a log); never ask whether you may look. Then tell the person briefly what you found and what you recommend. Start work that changes, sends, deletes or spends only with their yes.");
    }
    note
}

/// What the workspace types when it is the first to write to an agent that has not read its bot's
/// instructions: the instructions, as the app leads them in, and then the message.
pub(crate) fn instructed(instructions: &str, text: &str) -> String {
    format!("Standing instructions for this whole conversation:\n{instructions}\n\n{text}")
}

fn unseen() -> &'static str {
    "The person did not write this and can read both chats."
}

pub(crate) fn ask(cmd: &str, from: &str, id: i64, text: &str, set: &Settings) -> String {
    let from = line(from);
    format!(
        "{MESSAGE_LEAD} {from}, {PASSED_ON} ask #{id}\n{text}\n\
         ({from} needs an answer. {} Answer with: {cmd} bot reply {id} \"YOUR ANSWER\" (or refuse: {cmd} bot decline {id} \"WHY\"). If you must ask {from} something first, use: {cmd} bot ask \"{from}\" \"QUESTION\". Unanswered, it lapses {} from now.)",
        unseen(),
        span(set.ask_seconds)
    )
}

pub(crate) fn tell(from: &str, id: i64, text: &str) -> String {
    let from = line(from);
    format!(
        "{MESSAGE_LEAD} {from}, {PASSED_ON} tell #{id}\n{text}\n\
         (For your information: {from} expects no answer, so do not write back to it. {})",
        unseen()
    )
}

pub(crate) fn handoff(
    cmd: &str,
    from: &str,
    id: i64,
    text: &str,
    set: &Settings,
    from_person: bool,
) -> String {
    let from = line(from);
    let person = if from_person {
        " This work started with the person: also say the result in your reply here, which they read."
    } else {
        ""
    };
    format!(
        "{MESSAGE_LEAD} {from}, {PASSED_ON} hand-off #{id}\n{text}\n\
         ({from} asks you to take this work over. {} Within {} run: {cmd} bot accept {id} (or: {cmd} bot decline {id} \"WHY\"). Accept work you can carry out. For a failed prerequisite, check the configured routes and attempt an in-scope fix. After a fix, retry the original task and verify it. Once accepted, report the result to {from} with: {cmd} bot reply {id} \"RESULT\".{person} If you must ask {from} something first, use: {cmd} bot ask \"{from}\" \"QUESTION\".)",
        unseen(),
        span(set.handoff_accept_seconds)
    )
}

pub(crate) fn answer(from: &str, id: i64, text: &str) -> String {
    let from = line(from);
    format!(
        "{ANSWER_LEAD} {from}, {PASSED_ON} to your ask #{id}\n{text}\n\
         (This is {from}'s answer to what you asked it. The person did not write it. Go on with the work you asked this for, and tell the person what they need to know.)"
    )
}

pub(crate) fn report(from: &str, id: i64, text: &str, from_person: bool) -> String {
    let from = line(from);
    let person = if from_person {
        " This work started with the person: tell them the result."
    } else {
        ""
    };
    format!(
        "{REPORT_LEAD} {from}, {PASSED_ON} on your hand-off #{id}\n{text}\n\
         ({from} took this work over from you and reports its result. The person did not write this.{person})"
    )
}

/// `kind` is "ask" or "hand-off".
pub(crate) fn declined(from: &str, id: i64, kind: &str, reason: &str) -> String {
    let from = line(from);
    let yours = if kind == "ask" {
        ""
    } else {
        " The work is still yours."
    };
    format!(
        "{SERVER_LEAD} {from} declined your {kind} #{id}. Its reason: {reason}\n\
         (Do not send it to {from} again.{yours} Bring it to the person: tell them what you asked and why {from} declined.)"
    )
}

pub(crate) fn expired(to: &str, id: i64, kind: &str, seconds: u64, why: Option<&str>) -> String {
    let to = line(to);
    let what = match (kind, why) {
        (_, Some(why)) => format!("Your {kind} #{id} did not reach {to}: {why}"),
        ("ask", None) => format!(
            "{to} did not answer your ask #{id} within {}, so it ended unanswered.",
            span(seconds)
        ),
        (_, None) => format!(
            "{to} did not accept your hand-off #{id} within {}, so it ended. The work is still yours.",
            span(seconds)
        ),
    };
    format!(
        "{SERVER_LEAD} {what}\n(Do not send it again by yourself. Tell the person what you asked and that nothing came back.)"
    )
}

/// `why`: who or what ended the exchange, as a clause ("was stopped by the person").
pub(crate) fn stopped(who: &str, id: i64, kind: &str, why: &str) -> String {
    let who = line(who);
    format!(
        "{SERVER_LEAD} {who} {why}, so your {kind} #{id} ended without an answer.\n\
         (Do not write to {who} about this again. Tell the person where things stand.)"
    )
}

/// For a bot whose turn ended with another bot's ask or hand-off still open. `kind` is "ask" or "hand-off";
/// `left` is how many seconds it has left.
pub(crate) fn reminder(cmd: &str, from: &str, id: i64, kind: &str, left: Option<u64>) -> String {
    let from = line(from);
    let left = left.map_or_else(String::new, |left| {
        format!(" It lapses {} from now.", span(left / 60 * 60))
    });
    if kind == "ask" {
        format!(
            "{SERVER_LEAD} Your turn ended, and the ask #{id} from {from} is still open: what you write in your own chat does not reach {from}.\n\
             (If you have the answer, send it now: {cmd} bot reply {id} \"YOUR ANSWER\". If you are still working on it, send it when you have it. If you will not answer, run: {cmd} bot decline {id} \"WHY\".{left})"
        )
    } else {
        format!(
            "{SERVER_LEAD} Your turn ended, and the hand-off #{id} from {from} is still open: you have neither accepted nor declined it.\n\
             (Run: {cmd} bot accept {id}, or: {cmd} bot decline {id} \"WHY\".{left})"
        )
    }
}

/// A block of a reply that could not be passed on.
pub(crate) fn not_sent(to: &str, why: &str) -> String {
    format!(
        "{SERVER_LEAD} Your message to \"{}\" was not sent. {why}",
        line(to)
    )
}

/// `recurring`: how often it fires, in words, for one that recurs.
pub(crate) fn checkin(
    cmd: &str,
    id: i64,
    what: &str,
    recurring: Option<&str>,
    planned_ms: i64,
    zone: chrono_tz::Tz,
) -> String {
    let planned = clock(planned_ms, zone);
    match recurring {
        None => format!(
            "{CHECKIN_LEAD} #{id}, from SwarmHub] It was planned on {planned} for now: {what}\n\
             (The person did not write this now. Do it and say the outcome in your reply: the person reads it. This check-in was a one-off.)"
        ),
        Some(often) => format!(
            "{CHECKIN_LEAD} #{id}, from SwarmHub] It was planned on {planned} to recur {often}: {what}\n\
             (The person did not write this now. If there is something new to tell the person, say it in your reply. If there is nothing new, reply with exactly: {QUIET} — then the person is shown nothing. End it with `{cmd} checkin cancel {id}` when it is no longer needed.)"
        ),
    }
}

/// The same check-in a second time, after the first got no answer or did not arrive.
pub(crate) fn checkin_again(first: &str, typed: bool) -> String {
    format!(
        "{first}\n(Second try: {}. If you already did this, say the outcome now and do not do it twice.)",
        if typed { "the first one got no answer" } else { "the first one did not reach you" }
    )
}

pub(crate) fn promise(cmd: &str, id: i64, what: &str, due_ms: i64, zone: chrono_tz::Tz) -> String {
    format!(
        "{SERVER_LEAD} Your promise #{id} was due at {}: {what}\n\
         (Do it or report on it now, in your reply, which the person reads; then run: {cmd} promise done {id}. If you cannot keep it, say why. The person is told if it stays open.)",
        clock(due_ms, zone)
    )
}

pub(crate) fn main_note(lines: &[String]) -> String {
    let mut note = format!("{MAIN_LEAD} The person did not write this.\n");
    for line in lines {
        note.push_str("- ");
        note.push_str(line);
        note.push('\n');
    }
    note.push_str("(Look into this first when looking only reads: a terminal, a status, a log. Do not ask whether you may look. Then tell the person in a short message what happened, what you found and what you recommend. Start work that changes, sends, deletes or spends only with their yes.)");
    note
}

/// Whether a reply to a recurring check-in says that there is nothing to tell.
pub(crate) fn is_quiet(reply: &str) -> bool {
    let plain: String = reply
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();
    let quiet = QUIET.to_lowercase();
    plain == quiet || (plain.starts_with(&quiet) && reply.chars().count() <= 80)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bots::testing;

    #[test]
    fn the_standing_note_says_how_to_behave_and_only_the_commands_a_bot_may_use() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra", "Shop"]);
        let all: Vec<Bot> = ["Jarvis", "Infra", "Shop"]
            .iter()
            .map(|name| testing::bot(&history, name))
            .collect();
        let note = standing(&all[1], &all, "swarmhub-herdr", true, Autonomy::Careful);
        assert!(note.starts_with("[SwarmHub notes for the bot \"Infra\"]"));
        for said in [
            "Do what the person asks of you",
            "you only offer",
            "resume the authorized task",
            "wait for the person's yes",
            "Before deleting anything, sending something out of this server",
            "it needs no yes from the person",
            "ask the person and wait for their yes",
            "\"Jarvis\", \"Shop\"",
            "swarmhub-herdr bot ask NAME",
            "swarmhub-herdr bot tell NAME",
            "swarmhub-herdr bot handoff NAME",
            "swarmhub-herdr checkin in 30m",
            "swarmhub-herdr promise add --by 30m",
            "swarmhub-herdr bot job submit KEY -",
            "bot completion inbox",
            "swarmhub-herdr bot park file ID -",
        ] {
            assert!(note.contains(said), "{said}");
        }
        assert!(
            !note.contains("\"Infra\","),
            "a bot is not told to write to itself"
        );
        assert!(!note.contains("You are the main bot"));
        assert!(note.len() < 2_450, "{} bytes", note.len());
        // In Auto mode the bot finishes its task without asking about its steps; what cannot be taken back,
        // leaves the server or costs money still waits for the person.
        let auto = standing(&all[1], &all, "swarmhub-herdr", true, Autonomy::Balanced);
        for said in [
            "without asking permission for its steps",
            "Removing files that can be made again",
            "deleting data that cannot be made again or restored",
            "sending something out of this server to other people",
            "Ask once, with what you recommend",
            "look into it when looking only reads",
            "swarmhub-herdr bot ask NAME",
        ] {
            assert!(auto.contains(said), "{said}");
        }
        assert!(!auto.contains("Before deleting anything") && !auto.contains("you only offer"));
        assert!(auto.len() < 3_350, "{} bytes", auto.len());
        // Every level that still asks stops asking about what the person said not to ask about.
        for asks in [&note, &auto] {
            assert!(asks.contains("tells you not to ask about a kind of action"));
        }
        // The person can turn asking off altogether, and back on.
        let full = standing(&all[1], &all, "swarmhub-herdr", true, Autonomy::Full);
        for said in [
            "The person chose that you do not ask for permission",
            "Deleting, sending, spending and deploying that the task calls for are yours to decide",
            "Say in your report what you did that cannot be undone",
            "Never do what the person told you not to do",
        ] {
            assert!(full.contains(said), "{said}");
        }
        assert!(!full.contains("wait for their yes") && !full.contains("you only offer"));
        let told = autonomy_changed(Autonomy::Full);
        assert!(told.starts_with("[From SwarmHub] The person changed how much you ask") && told.contains("do not ask for permission"));
        assert!(crate::core::validate_task(&note).is_ok());
        let main = standing(&all[0], &all, "swarmhub-herdr", false, Autonomy::Careful);
        assert!(main.contains("You are the main bot") && main.contains("never ask whether you may look"));
        // The switches take the commands away, not only the permission.
        let silent = Bot {
            may_message: false,
            takes_initiative: false,
            ..all[0].clone()
        };
        let note = standing(&silent, &all, "swarmhub-herdr", false, Autonomy::Careful);
        assert!(note.contains("do not write to other bots, ask the person instead"));
        assert!(!note.contains("bot ask") && !note.contains("checkin in"));
        assert!(!note.contains("You are the main bot"));
        // A bot that takes no messages is not offered to the others.
        let closed = Bot {
            takes_messages: false,
            ..all[2].clone()
        };
        let note = standing(&all[1], &[all[0].clone(), all[1].clone(), closed], "x", false, Autonomy::Careful);
        assert!(note.contains("\"Jarvis\"") && !note.contains("\"Shop\""));
    }

    #[test]
    fn every_message_says_who_sent_it_and_how_to_answer() {
        let set = Settings::default();
        let asked = ask("sh", "Jarvis", 12, "Which port?", &set);
        assert!(asked.starts_with(
            "[Message from the bot Jarvis, passed on by SwarmHub] ask #12\nWhich port?\n"
        ));
        assert!(asked.contains("sh bot reply 12") && asked.contains("sh bot decline 12"));
        assert!(asked.contains("lapses 10 minutes from now"));
        let told = tell("Jarvis", 13, "Standup moved.");
        assert!(told.contains("tell #13") && told.contains("do not write back"));
        let handed = handoff("sh", "Jarvis", 14, "Ship it.", &set, true);
        assert!(
            handed.contains("hand-off #14")
                && handed.contains("Within 5 minutes run: sh bot accept 14")
        );
        assert!(handed.contains("sh bot reply 14") && handed.contains("started with the person"));
        assert!(
            !handoff("sh", "Jarvis", 14, "Ship it.", &set, false)
                .contains("started with the person")
        );
        assert!(answer("Infra", 12, "5432").starts_with(
            "[Answer from the bot Infra, passed on by SwarmHub] to your ask #12\n5432\n"
        ));
        assert!(report("Infra", 14, "Done.", true).contains("tell them the result"));
        assert!(declined("Infra", 14, "hand-off", "Not mine.").contains("Bring it to the person"));
        assert!(expired("Infra", 12, "ask", 600, None).contains("within 10 minutes"));
        assert!(expired("Infra", 14, "hand-off", 300, None).contains("The work is still yours"));
        assert!(
            expired(
                "Infra",
                12,
                "ask",
                600,
                Some("its agent could not be started.")
            )
            .contains("did not reach Infra")
        );
        assert!(
            stopped("Infra", 12, "ask", "was stopped by the person")
                .contains("Do not write to Infra about this again")
        );
        assert!(main_note(&["A helper stopped.".into()]).contains("Do not ask whether you may look."));
        let reminded = reminder("sh", "Jarvis", 12, "ask", Some(545));
        assert!(
            reminded.contains("the ask #12 from Jarvis is still open")
                && reminded.contains("sh bot reply 12")
        );
        assert!(
            reminded.contains("It lapses 9 minutes from now.")
                && crate::core::validate_task(&reminded).is_ok()
        );
        assert!(
            reminder("sh", "Jarvis", 14, "hand-off", None)
                .contains("Run: sh bot accept 14, or: sh bot decline 14")
        );
        for text in [asked, told, handed] {
            assert!(crate::core::validate_task(&text).is_ok());
        }
        assert_eq!(
            [
                span(600),
                span(300),
                span(90),
                span(60),
                span(3_600),
                span(7_200),
                span(1)
            ],
            [
                "10 minutes",
                "5 minutes",
                "90 seconds",
                "1 minute",
                "1 hour",
                "2 hours",
                "1 second"
            ]
        );
    }

    #[test]
    fn only_a_reply_that_says_nothing_else_is_quiet() {
        for quiet in [
            "NOTHING TO REPORT",
            "nothing to report.",
            "**Nothing to report**",
            " `NOTHING TO REPORT` \n",
            "Nothing to report: the flag file is not there yet.",
        ] {
            assert!(is_quiet(quiet), "{quiet}");
        }
        for loud in [
            "",
            "The deploy failed.",
            "There is nothing to report except that the disk is full.",
            "Nothing to report on the build, but the deploy failed twice and somebody should look at the logs soon.",
        ] {
            assert!(!is_quiet(loud), "{loud}");
        }
    }
}
