//! The socketpair isolates the provider double in a fixture executor process.
//! No host, URL, credentials, or command can be supplied on this channel.
use crate::outbound::{self, Adapter, Email, Executor, gmail::{self, Account, Found, Message, Provider, Search, SendReply}};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use std::{
    io::{self, Read, Write},
    net::Shutdown,
    os::unix::net::UnixStream,
    process::Child,
    sync::{Arc, Mutex},
    time::Duration,
};

const MAX_FRAME: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize)]
pub(crate) enum Mode {
    #[default]
    Accept,
    LoseReply,
    Revoke,
    DelayIndex,
    MultipleMatches,
    ChangedCopy,
    WrongAccount,
}

#[derive(Deserialize, Serialize)]
enum Request {
    Submit { email: Email, message_id: String, reserved_ms: i64 },
    Lookup { email: Email, message_id: String, reserved_ms: i64 },
    Mode(Mode),
    Counts,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct Counts {
    pub submission_attempts: usize,
    pub searches: usize,
    pub readbacks: usize,
}

struct Stored {
    account: String,
    message: Message,
    message_id: String,
}

struct Double {
    account: Account,
    mode: Mode,
    counts: Counts,
    sent: Vec<Stored>,
}

impl Provider for Double {
    fn send(&mut self, account: &str, message: &Message) -> SendReply {
        // Use the serialized Message-ID, just as the provider's Sent index would.
        let raw = URL_SAFE_NO_PAD.decode(&message.raw).unwrap();
        let raw = std::str::from_utf8(&raw).unwrap();
        let message_id = raw.lines().next().unwrap().strip_prefix("Message-ID: ").unwrap();
        self.counts.submission_attempts += 1;
        self.sent.push(Stored { account: account.into(), message: message.clone(), message_id: message_id.into() });
        if matches!(self.mode, Mode::LoseReply) {
            SendReply::Uncertain
        } else {
            SendReply::Response { status: 200, id: Some(format!("fixture-message-{}", self.sent.len())) }
        }
    }

    fn list(&mut self, search: &Search) -> Result<Vec<String>, ()> {
        self.counts.searches += 1;
        if search.label != "SENT" || matches!(self.mode, Mode::DelayIndex) {
            return Ok(vec![]);
        }
        let mut ids: Vec<_> = self.sent.iter().enumerate()
            .filter(|(_, message)| search.account == message.account
                && search.query == format!("rfc822msgid:{}", message.message_id))
            .map(|(index, _)| format!("fixture-message-{}", index + 1))
            .collect();
        if !ids.is_empty() && matches!(self.mode, Mode::MultipleMatches) {
            ids.push("different-fixture-id".into());
        }
        Ok(ids)
    }

    fn get_raw(&mut self, account: &str, id: &str) -> Result<Found, ()> {
        self.counts.readbacks += 1;
        let index: usize = id.strip_prefix("fixture-message-").ok_or(())?.parse().map_err(|_| ())?;
        let stored = index.checked_sub(1).and_then(|index| self.sent.get(index)).ok_or(())?;
        if stored.account != account {
            return Err(());
        }
        let mut message = stored.message.clone();
        if matches!(self.mode, Mode::ChangedCopy) {
            message.raw.push('A');
        }
        let account = if matches!(self.mode, Mode::WrongAccount) { "other@example.test" } else { account };
        Ok(Found { account: account.into(), id: id.into(), sent: true, message })
    }
}

impl Double {
    fn message(&self, email: &Email, message_id: &str, reserved_ms: i64) -> Option<Message> {
        if matches!(self.mode, Mode::Revoke) || !self.account.permits(email) || !outbound::message_id(message_id) {
            return None;
        }
        let snapshot = outbound::Payload::Email(email.clone());
        if snapshot.clone().normalize().ok().as_ref() != Some(&snapshot) {
            return None;
        }
        Message::from_snapshot(email, message_id, reserved_ms)
    }
}

pub(crate) fn serve(mut channel: UnixStream) -> io::Result<()> {
    let account: Account = read(&mut channel)?;
    let mut double = Double { account, mode: Mode::default(), counts: Counts::default(), sent: vec![] };
    loop {
        let request = match read::<Request>(&mut channel) {
            Ok(request) => request,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) => return Err(error),
        };
        match request {
            Request::Submit { email, message_id, reserved_ms } => {
                let reply = double.message(&email, &message_id, reserved_ms)
                    .map_or(SendReply::NotSubmitted, |message| double.send(&email.sender, &message));
                write(&mut channel, &reply)?;
            }
            Request::Lookup { email, message_id, reserved_ms } => {
                let id = double.message(&email, &message_id, reserved_ms).and_then(|message| {
                    gmail::find(&mut double, &email.sender, &message_id, &message)
                });
                write(&mut channel, &id)?;
            }
            Request::Mode(mode) => {
                double.mode = mode;
                write(&mut channel, &())?;
            }
            Request::Counts => write(&mut channel, &double.counts)?,
        }
    }
}

pub(crate) struct Fixture {
    channel: Mutex<UnixStream>,
    child: Child,
}

impl Fixture {
    pub(crate) fn start(account: Account) -> io::Result<(Executor, Arc<Self>)> {
        let (channel, child_socket) = UnixStream::pair()?;
        channel.set_read_timeout(Some(Duration::from_secs(5)))?;
        channel.set_write_timeout(Some(Duration::from_secs(5)))?;
        let child = crate::job_worker::tests::outbound_child(child_socket)?;
        let fixture = Arc::new(Self { channel: Mutex::new(channel), child });
        write(&mut *fixture.channel.lock().unwrap(), &account)?;
        Ok((Executor::fixture(account, fixture.clone()), fixture))
    }

    pub(crate) fn mode(&self, mode: Mode) {
        self.exchange::<()>(&Request::Mode(mode)).unwrap();
    }

    pub(crate) fn counts(&self) -> Counts {
        self.exchange(&Request::Counts).unwrap()
    }

    fn exchange<T: DeserializeOwned>(&self, request: &Request) -> io::Result<T> {
        let mut channel = self.channel.lock().map_err(|_| io::Error::other("Outbound executor channel is poisoned"))?;
        let result = write(&mut *channel, request).and_then(|_| read(&mut *channel));
        // A reply could still arrive after a timeout. Never reuse a broken frame stream.
        if result.is_err() {
            let _ = channel.shutdown(Shutdown::Both);
        }
        result
    }
}

impl Adapter for Fixture {
    fn submit(&self, email: &Email, message_id: &str, reserved_ms: i64) -> SendReply {
        self.exchange(&Request::Submit { email: email.clone(), message_id: message_id.into(), reserved_ms })
            .unwrap_or(SendReply::Uncertain)
    }

    fn lookup(&self, email: &Email, message_id: &str, reserved_ms: i64) -> Option<String> {
        self.exchange(&Request::Lookup { email: email.clone(), message_id: message_id.into(), reserved_ms })
            .ok().flatten()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let channel = self.channel.get_mut().unwrap_or_else(|error| error.into_inner());
        let _ = channel.shutdown(Shutdown::Both);
        let _ = self.child.wait();
    }
}

fn read<T: DeserializeOwned>(channel: &mut impl Read) -> io::Result<T> {
    let mut size = [0; 4];
    channel.read_exact(&mut size)?;
    let size = u32::from_be_bytes(size) as usize;
    if size > MAX_FRAME {
        return Err(io::Error::other("Oversized outbound executor frame"));
    }
    let mut data = vec![0; size];
    channel.read_exact(&mut data)?;
    serde_json::from_slice(&data).map_err(io::Error::other)
}

fn write(channel: &mut impl Write, value: &impl Serialize) -> io::Result<()> {
    let data = serde_json::to_vec(value).map_err(io::Error::other)?;
    if data.len() > MAX_FRAME {
        return Err(io::Error::other("Oversized outbound executor frame"));
    }
    channel.write_all(&(data.len() as u32).to_be_bytes())?;
    channel.write_all(&data)
}
