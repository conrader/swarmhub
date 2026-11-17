//! A change to one member of someone else's JSON file that leaves the rest of the file as it was.
//!
//! The file is read as a tree of objects whose members keep their order, and every value that is not on the way
//! to the member being changed keeps its exact text (`RawValue`): numbers are not reformatted, strings are not
//! re-escaped, nothing is sorted. Only the objects on the path are written anew, in the file's own style (indented
//! by two spaces when the file is, on one line when it is).

use serde::{
    Deserialize, Deserializer, Serialize, Serializer,
    de::{MapAccess, Visitor},
    ser::SerializeMap,
};
use serde_json::value::RawValue;

/// A value of the file: an object on the path to the change, or anything else, kept as its text.
pub(super) enum Node {
    Object(Vec<(String, Node)>),
    Kept(Box<RawValue>),
}

impl Serialize for Node {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Kept(text) => text.serialize(serializer),
            Self::Object(members) => {
                let mut map = serializer.serialize_map(Some(members.len()))?;
                for (name, value) in members {
                    map.serialize_entry(name, value)?;
                }
                map.end()
            }
        }
    }
}

/// The members of an object, in the file's order, each as its text.
struct Members(Vec<(String, Node)>);

impl<'de> Deserialize<'de> for Members {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct InOrder;
        impl<'de> Visitor<'de> for InOrder {
            type Value = Members;
            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a JSON object")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Members, A::Error> {
                let mut members = Vec::new();
                while let Some((name, value)) = map.next_entry::<String, Box<RawValue>>()? {
                    members.push((name, Node::Kept(value)));
                }
                Ok(Members(members))
            }
        }
        deserializer.deserialize_map(InOrder)
    }
}

fn kept(text: &str) -> Node {
    Node::Kept(RawValue::from_string(text.to_owned()).expect("a JSON literal"))
}

impl Node {
    /// The file's top: an object, or nothing this code will change.
    pub(super) fn read(text: &str) -> Option<Self> {
        serde_json::from_str::<Members>(text)
            .ok()
            .map(|members| Self::Object(members.0))
    }

    fn members(&mut self) -> Option<&mut Vec<(String, Node)>> {
        // A kept value that is an object is opened, once, when the change has to go through it.
        if let Self::Kept(text) = self {
            *self = Self::Object(serde_json::from_str::<Members>(text.get()).ok()?.0);
        }
        match self {
            Self::Object(members) => Some(members),
            Self::Kept(_) => None,
        }
    }

    /// The object member `name`, made (empty, at the end) when there is none. `None` when this is not an object, or
    /// the member is something other than an object. The flag says whether it was made now.
    pub(super) fn object(&mut self, name: &str) -> Option<(&mut Node, bool)> {
        let members = self.members()?;
        let made = !members.iter().any(|(member, _)| member == name);
        if made {
            members.push((name.to_owned(), Node::Object(Vec::new())));
        }
        let (_, value) = members.iter_mut().find(|(member, _)| member == name)?;
        value.members()?;
        Some((value, made))
    }

    /// The text of member `name`, when this is an object that has it.
    pub(super) fn text_of(&mut self, name: &str) -> Option<String> {
        self.members()?
            .iter()
            .find(|(member, _)| member == name)
            .map(|(_, value)| match value {
                Node::Kept(text) => text.get().trim().to_owned(),
                Node::Object(_) => "{…}".to_owned(),
            })
    }

    /// Sets member `name` to the JSON literal `value`, in place when it is there and at the end when it is not.
    pub(super) fn set(&mut self, name: &str, value: &str) -> Option<()> {
        let members = self.members()?;
        match members.iter_mut().find(|(member, _)| member == name) {
            Some((_, old)) => *old = kept(value),
            None => members.push((name.to_owned(), kept(value))),
        }
        Some(())
    }

    /// Takes member `name` out. True when it was there.
    pub(super) fn remove(&mut self, name: &str) -> bool {
        self.members().is_some_and(|members| {
            let before = members.len();
            members.retain(|(member, _)| member != name);
            members.len() != before
        })
    }

    pub(super) fn is_empty_object(&mut self) -> bool {
        self.members().is_some_and(|members| members.is_empty())
    }

    /// The file's text again, in the style `like` is written in, ending as `like` ends.
    pub(super) fn write(&self, like: &str) -> Option<String> {
        let indented = like.contains("\n  \"");
        let mut text = if indented {
            serde_json::to_string_pretty(self).ok()?
        } else {
            serde_json::to_string(self).ok()?
        };
        if like.ends_with('\n') {
            text.push('\n');
        }
        Some(text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FILE: &str = "{\n  \"numStartups\": 12,\n  \"cost\": 1.50,\n  \"note\": \"caf\\u00e9 \\/ x\",\n  \"projects\": {\n    \"/Users/ada/app\": {\n      \"allowedTools\": [],\n      \"hasTrustDialogAccepted\": true\n    }\n  },\n  \"zeta\": {\"b\":1,\"a\":2}\n}\n";

    #[test]
    fn a_change_leaves_every_other_value_and_the_order_as_they_were() {
        let mut file = Node::read(FILE).unwrap();
        let (projects, made) = file.object("projects").unwrap();
        assert!(!made);
        let (folder, made) = projects.object("/Users/ada/bots").unwrap();
        assert!(made);
        folder.set("hasTrustDialogAccepted", "true").unwrap();
        let written = file.write(FILE).unwrap();
        // Everything that was there is there, text for text: the number's zero, the escapes, the unsorted object.
        assert_eq!(
            written,
            "{\n  \"numStartups\": 12,\n  \"cost\": 1.50,\n  \"note\": \"caf\\u00e9 \\/ x\",\n  \"projects\": {\n    \"/Users/ada/app\": {\n      \"allowedTools\": [],\n      \"hasTrustDialogAccepted\": true\n    },\n    \"/Users/ada/bots\": {\n      \"hasTrustDialogAccepted\": true\n    }\n  },\n  \"zeta\": {\"b\":1,\"a\":2}\n}\n"
        );
        // Taking the change out again gives the file back, byte for byte.
        let mut file = Node::read(&written).unwrap();
        let (projects, _) = file.object("projects").unwrap();
        let (folder, _) = projects.object("/Users/ada/bots").unwrap();
        assert!(folder.remove("hasTrustDialogAccepted") && folder.is_empty_object());
        assert!(projects.remove("/Users/ada/bots"));
        assert_eq!(file.write(&written).unwrap(), FILE);
    }

    #[test]
    fn a_member_is_changed_in_place_and_a_file_on_one_line_stays_on_one_line() {
        let compact =
            r#"{"projects":{"/a":{"hasTrustDialogAccepted":false,"x":[1, 2]}},"last":null}"#;
        let mut file = Node::read(compact).unwrap();
        let (projects, _) = file.object("projects").unwrap();
        let (folder, made) = projects.object("/a").unwrap();
        assert!(!made);
        assert_eq!(
            folder.text_of("hasTrustDialogAccepted").as_deref(),
            Some("false")
        );
        folder.set("hasTrustDialogAccepted", "true").unwrap();
        assert_eq!(
            file.write(compact).unwrap(),
            r#"{"projects":{"/a":{"hasTrustDialogAccepted":true,"x":[1, 2]}},"last":null}"#
        );
        // A file without the object gets it at the end.
        let mut bare = Node::read("{}").unwrap();
        let (projects, made) = bare.object("projects").unwrap();
        assert!(made && projects.is_empty_object());
    }

    #[test]
    fn what_is_not_the_expected_shape_is_not_touched() {
        assert!(Node::read("[1, 2]").is_none());
        assert!(Node::read("{\"a\": 1").is_none());
        assert!(Node::read("").is_none());
        // `projects` that is not an object, and a folder entry that is not one.
        let mut odd = Node::read(r#"{"projects": []}"#).unwrap();
        assert!(odd.object("projects").is_none());
        let mut odd = Node::read(r#"{"projects": {"/a": "yes"}}"#).unwrap();
        let (projects, _) = odd.object("projects").unwrap();
        assert!(projects.object("/a").is_none());
    }
}
