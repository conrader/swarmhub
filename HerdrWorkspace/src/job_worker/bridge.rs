//! Fixed-argv fixture protocol for the coordinator's separate worker Core.
use super::{Attempt, INPUT_LIMIT, Manifest, PROTOCOL, Request, Result, Store, Worker, digest, providers, start, store::View};
use crate::{Core, core::{Failure, Program}, machines::probe::Provider};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use std::{io::{self, Write}, path::Path};

pub(crate) use super::store::View as WorkerView;

pub(crate) const PROGRAM: &str = "/usr/local/libexec/swarmhub-fixture-worker";
pub(crate) const STATE_DIR: &str = "/var/lib/swarmhub-fixture-worker";
const SECONDS: u64 = 3;

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub(crate) struct Placement {
    pub host_id: String,
    pub fingerprint: String,
    pub machine: String,
    pub target: String,
    pub project_created_ms: i64,
    pub provider: Provider,
    pub account_ref: String,
    pub profile: String,
}

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Verb {
    Start,
    Status,
    Cancel,
    Collect,
    Result,
}

impl Verb {
    fn name(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Status => "status",
            Self::Cancel => "cancel",
            Self::Collect => "collect",
            Self::Result => "result",
        }
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Call {
    request: Request,
    manifest_digest: String,
    result_digest: Option<String>,
}

#[derive(Deserialize, Serialize)]
struct Reply {
    protocol: u32,
    worker: Worker,
    attempt: Attempt,
    view: Option<View>,
    reason: Option<String>,
}

pub(crate) struct Ticket {
    start: Request,
    pub manifest_digest: String,
}

impl Ticket {
    pub(crate) fn new(
        placement: &Placement, job: &str, attempt: i64, owner: &str,
        submission: &crate::jobs::Submission, payload_digest: &str,
    ) -> Option<Self> {
        let manifest = Manifest {
            project_id: submission.project,
            project_created_ms: placement.project_created_ms,
            workdir: submission.workdir.clone(),
            owner_bot_id: owner.into(),
            provider: placement.provider,
            expected_account: Some(placement.account_ref.clone()),
            requested_model: submission.runtime.model.clone(),
            requested_effort: submission.runtime.effort.clone(),
            provider_run: Some(providers::Request {
                profile: placement.profile.clone(), brief: submission.brief.clone(),
            }),
        };
        let start = Request {
            protocol: PROTOCOL,
            worker: Worker { id: placement.host_id.clone(), host_fingerprint: placement.fingerprint.clone() },
            attempt: Attempt { job_id: job.into(), number: attempt },
            fixture: None,
            manifest: Some(manifest),
            payload_digest: Some(payload_digest.into()),
        };
        let manifest_digest = digest(&serde_json::to_vec(&start).ok()?);
        let ticket = Self { start, manifest_digest };
        (ticket.start.manifest.as_ref()?.valid() && ticket.payload(Verb::Start, None).is_some())
            .then_some(ticket)
    }

    fn payload(&self, verb: Verb, result_digest: Option<&str>) -> Option<String> {
        let mut request = self.start.clone();
        if !matches!(verb, Verb::Start) {
            request.manifest = None;
        }
        let call = Call {
            request,
            manifest_digest: self.manifest_digest.clone(),
            result_digest: result_digest.map(str::to_owned),
        };
        let bytes = serde_json::to_vec(&call).ok()?;
        (bytes.len() <= INPUT_LIMIT).then(|| URL_SAFE_NO_PAD.encode(bytes))
    }

    pub(crate) async fn request(
        &self, core: &Core, machine: &str, verb: Verb, result_digest: Option<&str>,
    ) -> std::result::Result<WorkerView, &'static str> {
        let payload = self.payload(verb, result_digest).ok_or("worker_request_invalid")?;
        let argv = [
            PROGRAM.into(), "job-worker".into(), "rpc".into(),
            STATE_DIR.into(), verb.name().into(), payload,
        ];
        let ran = core.run_on(machine, "/", Program::Argv(&argv), SECONDS).await.map_err(|error| {
            match error {
                Failure::Uncertain => "worker_reply_lost",
                Failure::Rejected(kind, _) if matches!(kind.as_str(), "spawn_failed" | "method_not_found") =>
                    "worker_incompatible",
                _ => "host_unreachable",
            }
        })?;
        if ran.timed_out {
            return Err("worker_reply_lost");
        }
        if ran.truncated || ran.signal.is_some() {
            return Err("worker_reply_lost");
        }
        if ran.code != Some(0) {
            return Err("worker_incompatible");
        }
        let bytes = base64::engine::general_purpose::STANDARD.decode(ran.stdout)
            .map_err(|_| "worker_incompatible")?;
        self.decode_reply(&bytes)
    }

    fn decode_reply(&self, bytes: &[u8]) -> std::result::Result<WorkerView, &'static str> {
        let reply: Reply = serde_json::from_slice(bytes).map_err(|_| "worker_incompatible")?;
        if reply.protocol != PROTOCOL {
            return Err("worker_incompatible");
        }
        if reply.worker != self.start.worker || reply.attempt != self.start.attempt {
            return Err("worker_identity_mismatch");
        }
        let view = reply.view.ok_or(match reply.reason.as_deref() {
            Some("manifest_mismatch") => "manifest_mismatch",
            _ => "worker_unavailable",
        })?;
        match view.manifest_digest.as_deref() {
            None if view.status == "missing" => Ok(view),
            Some(pin) if pin == self.manifest_digest => Ok(view),
            _ => Err("manifest_mismatch"),
        }
    }
}

pub(super) fn run(root: &Path, verb: &str, payload: &str) -> Result<()> {
    let verb = match verb {
        "start" => Verb::Start,
        "status" => Verb::Status,
        "cancel" => Verb::Cancel,
        "collect" => Verb::Collect,
        "result" => Verb::Result,
        _ => return Err("Unsupported fixture worker verb.".into()),
    };
    if payload.len() > (INPUT_LIMIT * 4).div_ceil(3) {
        return Err("Fixture worker request is too large.".into());
    }
    let bytes = URL_SAFE_NO_PAD.decode(payload)?;
    if bytes.len() > INPUT_LIMIT {
        return Err("Fixture worker request is too large.".into());
    }
    let Call { request, manifest_digest, result_digest } = serde_json::from_slice(&bytes)?;
    let mut reply = Reply {
        protocol: PROTOCOL,
        worker: request.worker.clone(),
        attempt: request.attempt.clone(),
        view: None,
        reason: None,
    };
    if request.protocol == PROTOCOL {
        let hex = |value: &str| crate::fleet_policy::principals::hex(value, 64);
        if !request.valid(verb.name()) || request.fixture.is_some()
            || request.manifest.as_ref().is_some_and(|manifest| manifest.expected_account.is_none())
            || !request.payload_digest.as_deref().is_some_and(hex)
            || !hex(&manifest_digest)
            || (matches!(verb, Verb::Result) != result_digest.as_deref().is_some_and(hex))
        {
            return Err("Invalid fixture worker request.".into());
        }
        match worker_view(root, &request, verb, &manifest_digest, result_digest.as_deref()) {
            Ok(Some(view)) => reply.view = Some(view),
            Ok(None) => reply.reason = Some("manifest_mismatch".into()),
            Err(_) => reply.reason = Some("worker_unavailable".into()),
        }
    }
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &reply)?;
    writeln!(out)?;
    Ok(())
}


fn worker_view(
    root: &Path, request: &Request, verb: Verb, manifest_digest: &str, result_digest: Option<&str>,
) -> Result<Option<View>> {
    let mut store = Store::open(root, Some(&request.worker))?;
    if let Some(manifest) = &request.manifest {
        if manifest_digest != digest(&serde_json::to_vec(request)?) {
            return Ok(None);
        }
        // Reserve checks the same pin again in its write transaction.
        if store.observe_bound(&request.attempt, false, false, Some(manifest_digest), None)?.is_none() {
            return Ok(None);
        }
        start(&mut store, request, manifest)?;
    }
    store.observe_bound(&request.attempt, matches!(verb, Verb::Cancel), false,
        Some(manifest_digest), result_digest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gapplan_10_unit_requires_the_worker_protocol_and_matching_attempt() {
        let placement = Placement {
            host_id: "fixture-worker".into(), fingerprint: format!("SHA256:{}", "A".repeat(43)),
            machine: "mini-m4".into(), target: "worker@mini-m4.invalid".into(), project_created_ms: 1,
            provider: Provider::Claude, account_ref: "fixture-account".into(), profile: "local".into(),
        };
        let mut submission = crate::jobs::tests::submission();
        submission.runtime.model = None;
        let ticket = Ticket::new(&placement, "fixture-job", 1, "fixture-owner",
            &submission, &"a".repeat(64)).unwrap();
        let mut reply = Reply {
            protocol: PROTOCOL - 1, worker: ticket.start.worker.clone(), attempt: ticket.start.attempt.clone(),
            view: None, reason: None,
        };
        let read = |reply: &Reply| ticket.decode_reply(&serde_json::to_vec(reply).unwrap()).err();
        assert_eq!(read(&reply), Some("worker_incompatible"));
        reply.protocol = PROTOCOL;
        reply.attempt.number += 1;
        assert_eq!(read(&reply), Some("worker_identity_mismatch"));
        reply.attempt.number -= 1;
        reply.reason = Some("manifest_mismatch".into());
        assert_eq!(read(&reply), Some("manifest_mismatch"));
    }
}
