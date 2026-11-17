//! The ```swarmhub blocks an agent may end a reply with. The Mac app taught agents to write to another bot with
//! `{"op":"message_bot","to":…,"message":…}` and to ask the main bot for a bot with `{"op":"request_bot",…}`,
//! and passed those on itself. For a registered bot the workspace passes them on, so an agent that still writes
//! them is heard with the app closed. `create_bot` and `decline_bot` stay the app's to read.

use serde_json::Value;

/// How much of a message and of an answer is passed on, as the app held it.
pub(crate) const MESSAGE_CHARS: usize = 4_000;
pub(crate) const ANSWER_CHARS: usize = 6_000;
const PER_REPLY: usize = 3;

/// Whether a line opens a ```swarmhub fence, and with how many ticks.
fn opens(line: &str) -> Option<usize> {
    let trimmed = line.trim();
    let ticks = trimmed.chars().take_while(|c| *c == '`').count();
    (ticks >= 3 && trimmed[ticks..].trim().eq_ignore_ascii_case("swarmhub")).then_some(ticks)
}

fn closes(line: &str, ticks: usize) -> bool {
    let line = line.trim();
    line.len() >= ticks && line.chars().all(|c| c == '`')
}

/// The bodies of a reply's closed ```swarmhub fences, and the reply without them. An unclosed fence is a reply
/// that was cut: nothing after its opening line is anyone's words.
fn split(reply: &str) -> (Vec<String>, String) {
    let lines: Vec<&str> = reply.split('\n').collect();
    let (mut bodies, mut kept, mut index) = (Vec::new(), Vec::new(), 0);
    while index < lines.len() {
        let Some(ticks) = opens(lines[index]) else {
            kept.push(lines[index]);
            index += 1;
            continue;
        };
        let end = (index + 1..lines.len()).find(|end| closes(lines[*end], ticks));
        match end {
            Some(end) => {
                bodies.push(lines[index + 1..end].join("\n"));
                index = end + 1;
            }
            None => index = lines.len(),
        }
    }
    (bodies, kept.join("\n").trim().to_owned())
}

/// A reply as another bot or the person reads it: without its blocks.
pub(crate) fn visible(reply: &str) -> String {
    split(reply).1
}

/// What a reply asks the workspace to pass on.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Block {
    /// `message_bot`. `kind` is `ask` unless the block says `tell` or `handoff`.
    Message {
        to: String,
        kind: String,
        text: String,
    },
    /// `request_bot`: for the main bot.
    Request { name: String, purpose: String },
}

fn one_line(value: Option<&Value>) -> Option<String> {
    let name = value?
        .as_str()?
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    (!name.is_empty() && name.chars().count() <= 40).then_some(name)
}

fn words(value: Option<&Value>, limit: usize) -> String {
    value
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .chars()
        .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
        .take(limit)
        .collect()
}

/// The blocks of a reply the workspace acts on, in order: at most three messages, one per name.
pub(crate) fn blocks(reply: &str) -> Vec<Block> {
    let mut found: Vec<Block> = Vec::new();
    for body in split(reply).0 {
        let objects = match serde_json::from_str::<Value>(&body) {
            Ok(Value::Array(objects)) => objects,
            Ok(object @ Value::Object(_)) => vec![object],
            _ => continue,
        };
        for object in objects {
            let block = match object["op"].as_str() {
                Some("message_bot") => {
                    let to = one_line(
                        object
                            .get("to")
                            .or(object.get("name"))
                            .or(object.get("bot")),
                    );
                    let text = words(object.get("message").or(object.get("text")), MESSAGE_CHARS);
                    let kind = match object["kind"].as_str() {
                        Some("tell") => "tell",
                        Some("handoff" | "hand_off" | "hand-off") => "handoff",
                        _ => "ask",
                    };
                    match to {
                        Some(to) if !text.is_empty() => Block::Message {
                            to,
                            kind: kind.into(),
                            text,
                        },
                        _ => continue,
                    }
                }
                Some("request_bot") => match one_line(object.get("name")) {
                    Some(name) => Block::Request {
                        name,
                        purpose: words(object.get("purpose").or(object.get("reason")), 1_500),
                    },
                    None => continue,
                },
                _ => continue,
            };
            let same = |seen: &Block| match (seen, &block) {
                (Block::Message { to: a, .. }, Block::Message { to: b, .. }) => {
                    a.to_lowercase() == b.to_lowercase()
                }
                (Block::Request { name: a, .. }, Block::Request { name: b, .. }) => {
                    a.to_lowercase() == b.to_lowercase()
                }
                _ => false,
            };
            if !found.iter().any(same) && found.len() < PER_REPLY {
                found.push(block);
            }
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reply_is_read_without_its_blocks_and_its_blocks_are_read_as_messages() {
        let reply = "I asked Infra.\n\n```swarmhub\n{\"op\":\"message_bot\",\"to\":\"Infra\",\"message\":\"Which port?\"}\n```\nMore words.";
        assert_eq!(visible(reply), "I asked Infra.\n\nMore words.");
        assert_eq!(
            blocks(reply),
            [Block::Message {
                to: "Infra".into(),
                kind: "ask".into(),
                text: "Which port?".into()
            }]
        );
        // Several objects in one block, a kind, a request for a bot, and what is not acted on here.
        let many = "````swarmhub\n[{\"op\":\"message_bot\",\"to\":\"A\",\"text\":\"one\",\"kind\":\"tell\"},\n {\"op\":\"message_bot\",\"to\":\"a\",\"text\":\"again\"},\n {\"op\":\"request_bot\",\"name\":\"Research\",\"purpose\":\"Reads papers\"},\n {\"op\":\"create_bot\",\"name\":\"X\"},\n {\"op\":\"message_bot\",\"to\":\"B\",\"message\":\"  \"}]\n````";
        assert_eq!(
            blocks(many),
            [
                Block::Message {
                    to: "A".into(),
                    kind: "tell".into(),
                    text: "one".into()
                },
                Block::Request {
                    name: "Research".into(),
                    purpose: "Reads papers".into()
                }
            ]
        );
        assert_eq!(visible(many), "");
        // A fence that never closes is a reply that was cut: no block, and nothing after its first line.
        let cut = "Words.\n```swarmhub\n{\"op\":\"message_bot\",\"to\":\"A\",\"message\":\"x\"}";
        assert!(blocks(cut).is_empty());
        assert_eq!(visible(cut), "Words.");
        // Another kind of fence is ordinary text, and bad JSON is no block.
        let code = "```sh\nls\n```\n```swarmhub\nnot json\n```";
        assert!(blocks(code).is_empty());
        assert_eq!(visible(code), "```sh\nls\n```");
    }
}
