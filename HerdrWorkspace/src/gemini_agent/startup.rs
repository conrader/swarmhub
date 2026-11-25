//! Gemini can request an OAuth code before it runs any hooks. Observe only the startup
//! screen; the first real hook takes ownership of status for the rest of this session.
use crate::core::Core;
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

fn terminal_device(path: &Path) -> bool {
    let Some(path) = path.to_str() else {
        return false;
    };
    // Slave PTYs returned by ttyname_r on Linux and macOS.
    path.strip_prefix("/dev/pts/")
        .or_else(|| path.strip_prefix("/dev/ttys"))
        .is_some_and(|id| !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()))
}

pub(super) fn register(journal: &Path, key: &str, tty: &Path) {
    let Some(path) = marker(journal, key) else {
        return;
    };
    let Ok(address) = std::env::var("HC_TERMINAL_ID") else {
        return;
    };
    if !crate::core::local_address(&address) || !terminal_device(tty) {
        return;
    }
    // Only the workspace that started a watcher creates this file.
    if let Ok(mut registration) = OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        && registration.metadata().is_ok_and(|m| m.is_file())
        && registration.lock().is_ok()
    {
        let _ = writeln!(registration, "{address}\n{}", tty.display());
    }
}

fn marker(journal: &Path, key: &str) -> Option<PathBuf> {
    (key.len() == 32 && key.bytes().all(|c| c.is_ascii_hexdigit()))
        .then(|| journal.with_file_name(format!(".gemini-start-{key}")))
}

/// Serialize the first hook with a possible last observation of the old OAuth screen.
pub(super) fn finish(journal: &Path, key: &str) {
    if let Some(path) = marker(journal, key)
        && let Ok(file) = open_marker(&path)
        && file.lock().is_ok()
    {
        let _ = fs::remove_file(path);
    }
}

fn open_marker(path: &Path) -> std::io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(std::io::ErrorKind::InvalidData.into());
    }
    Ok(file)
}

fn awaiting_code(screen: &str) -> bool {
    // Core may wrap either line when the attached terminal is narrow.
    let text: String = screen.split_whitespace().collect();
    text.contains("PleasevisitthefollowingURLtoauthorizetheapplication:")
        && text.ends_with("Entertheauthorizationcode:")
}

pub(crate) fn watch(core: &Core, journal: &Path, key: &str, template: &crate::core::Template) {
    // The path to the wrapper may be shell-quoted. Only run-gemini can register the launch.
    if !template
        .command
        .split_ascii_whitespace()
        .any(|arg| arg == "run-gemini")
    {
        return;
    }
    let core = core.clone();
    let Some(path) = marker(journal, key) else {
        return;
    };
    let Ok(registration) = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
    else {
        return;
    };
    let key = key.to_owned();
    tokio::spawn(async move {
        // Core can still be waiting inside terminal.run for the very first status.
        let _ =
            tokio::time::timeout(Duration::from_secs(85), observe(&core, &key, registration)).await;
        let _ = fs::remove_file(path);
    });
}

async fn observe(core: &Core, key: &str, registration: File) -> Option<()> {
    let mut tick = tokio::time::interval(Duration::from_millis(400));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        let state = registration.metadata().ok()?;
        if state.nlink() == 0 {
            return None;
        }
        if state.len() != 0 {
            break;
        }
    }
    let mut text = String::new();
    registration.lock().ok()?;
    (&registration).take(512).read_to_string(&mut text).ok()?;
    registration.unlock().ok()?;
    let (address, device) = text.trim_end().split_once('\n')?;
    if !terminal_device(Path::new(device)) {
        return None;
    }
    // Hold the PTY open across identity checks so a reused device number cannot receive a report.
    let mut tty = OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NOCTTY | libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(device)
        .ok()?;
    if !tty.metadata().ok()?.file_type().is_char_device() {
        return None;
    }
    let agent = core
        .agents()
        .await
        .ok()?
        .into_iter()
        .find(|a| a.address == address && a.launch_key() == Some(key))?;
    loop {
        let live = core.agent(&agent.address, agent.created_ms).await.ok()?;
        if live.launch_key() != Some(key) || live.require_live().is_err() || live.reported() {
            return None;
        }
        let screen = core.output(&live).await.ok()?;
        if awaiting_code(&screen.text) {
            registration.lock().ok()?;
            if registration.metadata().ok()?.nlink() != 0 {
                tty.write_all(super::status::line("blocked", Some("auth")).as_bytes())
                    .ok()?;
            }
            return Some(());
        }
        tick.tick().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_an_active_oauth_prompt_while_starting_is_recognized() {
        let prompt = "Please visit the following URL to autho\nrize the application:\n\nhttps://example.invalid/qa\nEnter the authoriz\nation code: ";
        assert!(awaiting_code(prompt));
        assert!(!awaiting_code(&format!("{prompt}\nType your message")));
        assert!(!awaiting_code("Enter the authorization code:"));
        assert!(terminal_device(Path::new("/dev/ttys003")));
        assert!(terminal_device(Path::new("/dev/pts/24")));
        assert!(!terminal_device(Path::new("/dev/pts/../tty")));
        assert!(!terminal_device(Path::new("/dev/null")));
    }
}
