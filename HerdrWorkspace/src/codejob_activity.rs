//! Operator-scoped sb-codejob observations. No managed-job or native session records participate.
use crate::{Core, core::Machine};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use futures_util::future::join_all;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

pub(crate) const PROBE: &str = include_str!("codejob_activity/probe.py");

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Host {
    id: String,
    machine: Option<String>,
    target: Option<String>,
    scope: Scope,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Scope {
    hostname: String,
    runner_host: String,
    root: String,
    owners: Vec<Owner>,
    executables: BTreeMap<String, String>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Owner {
    agent: String,
    workdir: String,
    bot_id: String,
}

fn absolute(path: &str) -> bool {
    path.len() <= 1024
        && path.starts_with('/')
        && !path.chars().any(char::is_control)
        && path[1..].split('/').all(|p| !matches!(p, "" | "." | ".."))
}

fn label(s: &str) -> bool {
    (1..=64).contains(&s.len())
        && s.as_bytes()[0].is_ascii_alphanumeric()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

fn uuid(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => b == b'-',
            _ => b.is_ascii_hexdigit(),
        })
}

impl Host {
    fn valid(&self) -> bool {
        let s = &self.scope;
        label(&self.id)
            && label(&s.hostname)
            && label(&s.runner_host)
            && absolute(&s.root)
            && match (&self.machine, &self.target) {
                (None, None) => true,
                (Some(m), Some(t)) => {
                    crate::core::valid_name(m)
                        && !t.is_empty()
                        && t.len() <= 254
                        && !t.chars().any(char::is_whitespace)
                        && !t.chars().any(char::is_control)
                }
                _ => false,
            }
            && (1..=64).contains(&s.owners.len())
            && s.owners.iter().all(|o| {
                uuid(&o.bot_id)
                    && absolute(&o.workdir)
                    && (1..=64).contains(&o.agent.len())
                    && o.agent.as_bytes()[0].is_ascii_alphanumeric()
                    && o.agent
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b" ._-".contains(&b))
            })
            && !s.executables.is_empty()
            && s.executables
                .iter()
                .all(|(k, p)| matches!(k.as_str(), "codex" | "claude") && absolute(p))
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum State {
    Working,
    Queued,
    Wrapper,
    Unknown,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Job {
    owner: String,
    job: String,
    state: State,
    provider: Option<String>,
}

#[derive(Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Reading {
    complete: bool,
    jobs: Vec<Job>,
}

#[derive(Serialize)]
pub(crate) struct HostReading {
    host: String,
    #[serde(flatten)]
    reading: Reading,
}

impl Host {
    fn connection<'a>(&self, machines: &'a [Machine]) -> Option<&'a Machine> {
        let name = self.machine.as_ref()?;
        let mut named = machines.iter().filter(|m| &m.name == name);
        let m = named.next()?;
        (named.next().is_none()
            && !m.temporary
            && !m.via
            && m.state == "connected"
            && Some(&m.target) == self.target.as_ref())
        .then_some(m)
    }

    async fn read(&self, core: &Core, machines: &[Machine]) -> Option<Reading> {
        if self.machine.is_some() {
            self.connection(machines)?;
        }
        let scope = serde_json::to_string(&self.scope).ok()?;
        let ran = core
            .codejob_activity(self.machine.as_deref(), &scope)
            .await
            .ok()?;
        self.decode(ran)
    }

    fn decode(&self, ran: crate::core::Ran) -> Option<Reading> {
        if ran.code != Some(0)
            || ran.timed_out
            || ran.truncated
            || ran.signal.is_some()
            || ran.stdout.len() > 128 * 1024
        {
            return None;
        }
        let reading: Reading = serde_json::from_slice(&STANDARD.decode(ran.stdout).ok()?).ok()?;
        let mut jobs = HashSet::new();
        (reading.jobs.len() <= 256
            && reading.jobs.iter().all(|j| {
                crate::fleet_policy::principals::hex(&j.job, 64)
                    && jobs.insert(&j.job)
                    && self.scope.owners.iter().any(|o| o.bot_id == j.owner)
                    && match (&j.state, &j.provider) {
                        (State::Working, Some(p)) => self.scope.executables.contains_key(p),
                        (State::Working, None) => false,
                        (_, provider) => provider.is_none(),
                    }
            }))
        .then_some(reading)
    }
}

/// None is a failed configuration read. An empty array is an explicitly unconfigured bridge.
pub(crate) async fn snapshot(core: &Core, supports_exec: bool) -> Option<Vec<HostReading>> {
    let raw = match std::env::var("SWARMHUB_CODEJOB_HOSTS") {
        Ok(raw) => raw,
        Err(std::env::VarError::NotPresent) => return Some(vec![]),
        Err(_) => return None,
    };
    if raw.len() > 64 * 1024 {
        return None;
    }
    let hosts: Vec<Host> = serde_json::from_str(&raw).ok()?;
    let mut ids = HashSet::new();
    let mut endpoints = HashSet::new();
    if hosts.len() > 8
        || !hosts
            .iter()
            .all(|h| h.valid() && ids.insert(&h.id) && endpoints.insert(&h.target))
    {
        return None;
    }
    let machines = if supports_exec && hosts.iter().any(|h| h.machine.is_some()) {
        core.machines().await.unwrap_or_default()
    } else {
        vec![]
    };
    let mut results = join_all(hosts.iter().map(|host| async {
        let reading = if supports_exec {
            host.read(core, &machines).await
        } else {
            None
        };
        HostReading {
            host: host.id.clone(),
            reading: reading.unwrap_or_default(),
        }
    }))
    .await;
    // Core machine names can be rebound during a read. Discard observations if
    // the persistent registration or connection changed while the probe ran.
    if hosts.iter().any(|h| h.connection(&machines).is_some()) {
        let current = core.machines().await.unwrap_or_default();
        for (host, result) in hosts.iter().zip(&mut results) {
            if host.machine.is_some()
                && !host
                    .connection(&machines)
                    .zip(host.connection(&current))
                    .is_some_and(|(a, b)| {
                        a.session == b.session && a.host == b.host && a.since_ms == b.since_ms
                    })
            {
                result.reading = Reading::default();
            }
        }
    }
    Some(results)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn host() -> Host {
        serde_json::from_value(json!({"id":"dmt", "machine":"dmt", "target":"runner@dmt",
            "scope":{"hostname":"serwerDMT", "runner_host":"serwerDMT", "root":"/work",
            "owners":[{"bot_id":"00112233-4455-6677-8899-aabbccddeeff", "agent":"Swarmhub", "workdir":"/project"}],
            "executables":{"codex":"/opt/bin/codex"}}})).unwrap()
    }

    fn output(jobs: Value) -> crate::core::Ran {
        serde_json::from_value(
            json!({"code":0,"timed_out":false,"truncated":false,"ms":1,"stderr":"",
            "stdout":STANDARD.encode(json!({"jobs":jobs,"complete":true}).to_string())}),
        )
        .unwrap()
    }

    #[test]
    fn only_the_pinned_persistent_connection_qualifies() {
        let h = host();
        let machine = |target, state, via| {
            serde_json::from_value(json!({
                "name":"dmt","target":target,"state":state,"via":via
            }))
            .unwrap()
        };
        assert!(
            h.connection(&[machine("runner@dmt", "connected", false)])
                .is_some()
        );
        assert!(
            h.connection(&[machine("other@dmt", "connected", false)])
                .is_none()
        );
        assert!(
            h.connection(&[machine("runner@dmt", "unreachable", false)])
                .is_none()
        );
        assert!(
            h.connection(&[machine("runner@dmt", "connected", true)])
                .is_none()
        );
    }

    #[test]
    fn scope_and_reply_are_closed() {
        let mut h = host();
        assert!(h.valid());
        let mut row = json!({"job":"a".repeat(64),"owner":h.scope.owners[0].bot_id,"state":"working","provider":"codex"});
        assert!(h.decode(output(json!([row]))).is_some());
        assert!(h.decode(output(json!([row, row]))).is_none());
        row["provider"] = "claude".into();
        assert!(h.decode(output(json!([row]))).is_none());
        row["provider"] = "codex".into();
        row["owner"] = "Swarmhub".into();
        assert!(h.decode(output(json!([row]))).is_none());
        h.scope.owners[0].agent = "../Swarmhub".into();
        assert!(!h.valid());
    }
}
