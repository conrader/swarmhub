//! Whether a way to sign in to Gemini CLI has been chosen on this computer.
//!
//! Gemini CLI runs its SessionStart hook while its sign-in question is still on screen. The hook must not call
//! that ready, so it looks, reading only, at where Gemini CLI keeps the choice: `security.auth.selectedType` in
//! its settings. This says a way was chosen, not that signing in works; a sign-in that has run out still needs
//! the person at the terminal.

use std::{
    env,
    fs::File,
    io::Read,
    path::{Path, PathBuf},
};

const MAX_SETTINGS: u64 = 1024 * 1024;

/// Whether Gemini CLI will start without asking how to sign in.
pub(super) fn chosen() -> bool {
    decide(
        &|name| env::var(name).ok().filter(|value| !value.is_empty()),
        &settings_files(),
    )
}

fn decide(env: &dyn Fn(&str) -> Option<String>, files: &[PathBuf]) -> bool {
    let set = |name: &str| env(name).is_some();
    // On these machines Gemini CLI chooses for itself.
    if ["CLOUD_SHELL", "GEMINI_CLI_USE_COMPUTE_ADC"]
        .iter()
        .any(|name| env(name).as_deref() == Some("true"))
    {
        return true;
    }
    match files.iter().find_map(|file| selected(file)).as_deref() {
        None => false,
        // Vertex AI is refused again at every start without these, and the question comes back.
        Some("vertex-ai") => {
            set("GOOGLE_API_KEY") || (set("GOOGLE_CLOUD_PROJECT") && set("GOOGLE_CLOUD_LOCATION"))
        }
        Some(_) => true,
    }
}

/// Where Gemini CLI reads settings from, apart from the bot's folder: the person's own, then the computer's.
fn settings_files() -> Vec<PathBuf> {
    let mut files = Vec::new();
    let home = env::var_os("GEMINI_CLI_HOME")
        .or_else(|| env::var_os("HOME"))
        .map(PathBuf::from)
        .filter(|home| home.is_absolute());
    if let Some(home) = home {
        files.push(home.join(".gemini/settings.json"));
    }
    let system = env::var_os("GEMINI_CLI_SYSTEM_SETTINGS_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if cfg!(target_os = "macos") {
                "/Library/Application Support/GeminiCli/settings.json".into()
            } else {
                "/etc/gemini-cli/settings.json".into()
            }
        });
    let defaults = env::var_os("GEMINI_CLI_SYSTEM_DEFAULTS_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| system.with_file_name("system-defaults.json"));
    files.extend([system, defaults]);
    files
}

/// The chosen way to sign in that a settings file names, if it names one. The file is only read.
fn selected(file: &Path) -> Option<String> {
    let mut text = String::new();
    File::open(file)
        .ok()?
        .take(MAX_SETTINGS)
        .read_to_string(&mut text)
        .ok()?;
    selected_in(&text)
}

fn selected_in(text: &str) -> Option<String> {
    let named = |value: &serde_json::Value| {
        value["security"]["auth"]["selectedType"]
            .as_str()
            .or_else(|| value["selectedAuthType"].as_str())
            .filter(|kind| !kind.is_empty())
            .map(str::to_owned)
    };
    match serde_json::from_str::<serde_json::Value>(text) {
        Ok(value) => named(&value),
        // Gemini CLI allows comments in its settings. Find the value by its name then.
        Err(_) => ["\"selectedType\"", "\"selectedAuthType\""]
            .iter()
            .find_map(|name| {
                let rest = text.split_once(name)?.1.trim_start().strip_prefix(':')?;
                let value = rest.trim_start().strip_prefix('"')?.split_once('"')?.0;
                (!value.is_empty()).then(|| value.to_owned())
            }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_settings_file_names_the_chosen_way_to_sign_in() {
        assert_eq!(
            selected_in(r#"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#).as_deref(),
            Some("oauth-personal")
        );
        assert_eq!(
            selected_in(r#"{"selectedAuthType":"gemini-api-key"}"#).as_deref(),
            Some("gemini-api-key")
        );
        assert_eq!(selected_in(r#"{"security":{"auth":{}}}"#), None);
        assert_eq!(selected_in(r#"{"ui":{"theme":"Default"}}"#), None);
        assert_eq!(selected_in(""), None);
        // With a comment in it, as Gemini CLI allows.
        assert_eq!(
            selected_in("{\n  // my settings\n  \"security\": {\"auth\": {\"selectedType\" : \"vertex-ai\"}}\n}")
                .as_deref(),
            Some("vertex-ai")
        );
        assert_eq!(
            selected_in("{ // nothing chosen\n \"selectedType\": null }"),
            None
        );
    }

    #[test]
    fn nothing_chosen_means_the_sign_in_question_is_on_screen() {
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("settings.json");
        let files = [folder.path().join("missing.json"), file.clone()];
        let none = |_: &str| None;
        assert!(!decide(&none, &files));
        std::fs::write(&file, r#"{"ui":{}}"#).unwrap();
        assert!(!decide(&none, &files));
        std::fs::write(
            &file,
            r#"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#,
        )
        .unwrap();
        assert!(decide(&none, &files));

        // Vertex AI needs its project and place, or a key, every time.
        std::fs::write(
            &file,
            r#"{"security":{"auth":{"selectedType":"vertex-ai"}}}"#,
        )
        .unwrap();
        assert!(!decide(&none, &files));
        let project = |name: &str| (name == "GOOGLE_CLOUD_PROJECT").then(|| "example".to_owned());
        assert!(!decide(&project, &files));
        let both = |name: &str| {
            matches!(name, "GOOGLE_CLOUD_PROJECT" | "GOOGLE_CLOUD_LOCATION")
                .then(|| "example".to_owned())
        };
        assert!(decide(&both, &files));

        // A machine where Gemini CLI chooses for itself.
        let shell = |name: &str| (name == "CLOUD_SHELL").then(|| "true".to_owned());
        assert!(decide(&shell, &[]));
        assert!(!decide(&none, &[]));
    }
}
