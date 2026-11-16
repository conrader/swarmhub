use std::{
    env, fs,
    io::{self, BufRead, Write},
    os::unix::{
        fs::{DirBuilderExt, OpenOptionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

use ring::rand::{SecureRandom, SystemRandom};

struct Display {
    folder: PathBuf,
    children: Vec<Child>,
}

impl Drop for Display {
    fn drop(&mut self) {
        for child in self.children.iter_mut().rev() {
            let _ = child.kill();
        }
        for child in self.children.iter_mut().rev() {
            let _ = child.wait();
        }
        let _ = fs::remove_dir_all(&self.folder);
    }
}

pub(super) fn folder(journal: &Path, key: &str) -> Option<PathBuf> {
    (key.len() == 32 && key.bytes().all(|b| b.is_ascii_hexdigit()))
        .then(|| journal.with_file_name(format!("desktop-{key}")))
}

pub(super) fn socket(folder: &Path, control: bool) -> PathBuf {
    folder.join(if control { "control" } else { "view" })
}

fn authorize(path: &Path) -> io::Result<()> {
    let mut cookie = [0u8; 16];
    SystemRandom::new()
        .fill(&mut cookie)
        .map_err(|_| io::Error::other("could not create display authorization"))?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    // Xauthority FamilyWild; the random cookie is confined to this display's directory.
    file.write_all(&65535_u16.to_be_bytes())?;
    for field in [b"".as_slice(), b"", b"MIT-MAGIC-COOKIE-1", &cookie] {
        file.write_all(
            &u16::try_from(field.len())
                .expect("fixed field length")
                .to_be_bytes(),
        )?;
        file.write_all(field)?;
    }
    Ok(())
}

fn owned_child(command: &mut Command) -> io::Result<Child> {
    #[cfg(target_os = "linux")]
    {
        // A hard stop can bypass Drop. The display children must die with the runner.
        let parent = std::process::id();
        // SAFETY: the fork child makes only async-signal-safe system calls before exec.
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::getppid() as u32 != parent {
                    libc::_exit(1);
                }
                Ok(())
            });
        }
    }
    command.spawn()
}

pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    const USAGE: &str = "Usage: swarmhub-herdr run-desktop -- COMMAND [ARG ...]";
    let mut args = env::args_os().skip(2);
    if args.next().as_deref() != Some(std::ffi::OsStr::new("--")) {
        return Err(USAGE.into());
    }
    let command = args.next().ok_or(USAGE)?;
    let (journal, identity) = crate::agent::session()?;
    let db = crate::history::connection(&journal)?;
    let registered: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM journal WHERE launch_key=?1)",
        [&identity],
        |row| row.get(0),
    )?;
    drop(db);
    if !registered {
        return Err("This desktop must belong to a SwarmHub launch.".into());
    }
    let folder = folder(&journal, &identity).ok_or("Invalid desktop identity.")?;
    fs::DirBuilder::new().mode(0o700).create(&folder)?;
    let mut display = Display {
        folder,
        children: Vec::new(),
    };
    let auth = display.folder.join("xauth");
    authorize(&auth)?;
    let mut server = owned_child(
        Command::new("/usr/bin/Xvfb")
            .args([
                "-displayfd",
                "1",
                "-nolisten",
                "tcp",
                "-screen",
                "0",
                "1280x800x24",
                "-auth",
            ])
            .arg(&auth)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null()),
    )?;
    let pipe = server
        .stdout
        .take()
        .ok_or("Could not open the display startup pipe.")?;
    display.children.push(server);
    let (ready, result) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let mut number = String::new();
        let _ = io::BufReader::new(std::io::Read::take(pipe, 12)).read_line(&mut number);
        let _ = ready.send(number.trim().parse::<u16>());
    });
    let number = result
        .recv_timeout(Duration::from_secs(20))
        .map_err(|_| "Timed out opening the isolated X11 display.")?
        .map_err(|_| "Xvfb could not open the isolated X11 display.")?;
    let port = format!(":{number}");
    for control in [false, true] {
        let path = socket(&display.folder, control);
        let mut vnc = Command::new("/usr/bin/x11vnc");
        vnc.args(["-display", &port, "-auth"])
            .arg(&auth)
            .arg("-unixsock")
            .arg(path)
            .args([
                "-rfbport",
                "0",
                "-noipv6",
                "-forever",
                "-shared",
                "-nopw",
                "-novncconnect",
                "-noremote",
                "-nocmds",
                "-nolookup",
                "-nosel",
                "-input",
                if control { "KMB" } else { "" },
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if !control {
            vnc.arg("-viewonly");
        }
        display.children.push(owned_child(&mut vnc)?);
    }
    let until = Instant::now() + Duration::from_secs(15);
    while ![false, true]
        .into_iter()
        .all(|control| socket(&display.folder, control).exists())
    {
        if Instant::now() >= until
            || display
                .children
                .iter_mut()
                .any(|child| matches!(child.try_wait(), Ok(Some(_))))
        {
            return Err(
                "The private desktop could not be started. Check Xvfb and x11vnc installation."
                    .into(),
            );
        }
        thread::sleep(Duration::from_millis(50));
    }
    let status = owned_child(
        Command::new(command)
            .args(args)
            .env("DISPLAY", port)
            .env("XAUTHORITY", auth)
            .env_remove("WAYLAND_DISPLAY"),
    )?
    .wait()?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("The desktop agent exited: {status}.").into())
    }
}
