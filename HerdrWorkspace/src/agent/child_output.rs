use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
pub(crate) struct ChildCommandOutput {
    pub command: String,
    pub output: String,
}

impl ChildCommandOutput {
    pub fn new(command: &str, output: &str) -> Option<Self> {
        if command.trim().is_empty() || output.trim().is_empty() {
            return None;
        }
        let start = output.ceil_char_boundary(output.len().saturating_sub(8192));
        Some(Self {
            command: command[..command.floor_char_boundary(command.len().min(2048))].into(),
            output: output[start..].into(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_the_end_of_long_multibyte_command_output() {
        let text = format!("{} failure", "中".repeat(4000));
        let value = ChildCommandOutput::new("run tests", &text).unwrap();
        assert!(
            value.output.len() <= 8192
                && text.ends_with(&value.output)
                && value.output.ends_with(" failure")
        );
        assert!(ChildCommandOutput::new("run tests", "  ").is_none());
    }
}
