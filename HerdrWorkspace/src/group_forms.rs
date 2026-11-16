use crate::core::Failure;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

pub type Values = BTreeMap<String, String>;
const PREFIX: &str = "Form response: ";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Form {
    pub title: String,
    pub fields: Vec<Field>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Field {
    key: String,
    label: String,
    #[serde(default = "required")]
    required: bool,
    choices: Option<Vec<String>>,
}

fn required() -> bool {
    true
}

fn safe_label(text: &str, max: usize) -> bool {
    !text.is_empty()
        && text.len() <= max
        && text.trim() == text
        && !text.chars().any(char::is_control)
}

impl Form {
    pub fn parse(input: &str) -> Result<Self, &'static str> {
        let form: Self =
            serde_json::from_str(input).map_err(|_| "Provide a valid group form as JSON.")?;
        let mut keys = HashSet::new();
        if !safe_label(&form.title, 120)
            || !(1..=6).contains(&form.fields.len())
            || form.fields.iter().any(|field| {
                !valid_key(&field.key)
                    || !keys.insert(field.key.as_str())
                    || !safe_label(&field.label, 100)
                    || field.choices.as_ref().is_some_and(|choices| {
                        let distinct = choices.iter().collect::<HashSet<_>>();
                        !(2..=8).contains(&choices.len())
                            || distinct.len() != choices.len()
                            || choices.iter().any(|choice| !safe_label(choice, 100))
                    })
            })
        {
            return Err(
                "Use 1–6 distinct form fields with short labels, and 2–8 distinct choices for each choice field.",
            );
        }
        Ok(form)
    }

    pub fn response(&self, inputs: Values) -> Result<String, Failure> {
        const INVALID: Failure = Failure::Input(
            "Complete required fields and use the listed choices. Text fields can contain up to 300 bytes.",
        );
        let mut values = Values::new();
        for (key, value) in inputs {
            let field = self
                .fields
                .iter()
                .find(|field| field.key == key)
                .ok_or(INVALID)?;
            let value = value.trim();
            if value.is_empty() {
                if field.required {
                    return Err(INVALID);
                }
                continue;
            }
            if !safe_label(value, 300)
                || field
                    .choices
                    .as_ref()
                    .is_some_and(|options| !options.iter().any(|option| option == value))
            {
                return Err(INVALID);
            }
            values.insert(key, value.to_owned());
        }
        if self
            .fields
            .iter()
            .any(|field| field.required && !values.contains_key(&field.key))
        {
            return Err(INVALID);
        }
        Ok(format!("{PREFIX}{}", serde_json::json!(values)))
    }
}

fn valid_key(key: &str) -> bool {
    (1..=24).contains(&key.len())
        && key
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
}
