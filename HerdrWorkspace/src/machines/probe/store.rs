use super::*;
use crate::{
    fleet_policy::{self, Authority, Role},
    history,
};
use rusqlite::{Connection, OptionalExtension, params};
use std::io::Write;

pub(crate) const USAGE: &str =
    "Fixture workers: worker-probe [payload|record] (bounded JSON on standard input)";

pub(crate) fn cli() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(2);
    let verb = args.next();
    if args.next().is_some() {
        return Err(USAGE.into());
    }
    match verb.as_deref() {
        None => emit(std::io::stdout().lock())?,
        Some("payload") => {
            let report: Report = serde_json::from_str(&crate::agent::read_input(LIMIT)?)?;
            let payload = report.canonical().map_err(Reason::message)?;
            println!("{}", STANDARD.encode(payload));
        }
        Some("record") => {
            let probe = input()?;
            let authority = Authority::configured(Role::Bridge)?
                .ok_or(fleet_policy::Error::Unavailable)?;
            let path = history::private_directory()?.join("workspace.sqlite3");
            let mut journal = history::connection(&path)?;
            record(&authority, &mut journal, &probe, history::now())?;
        }
        _ => return Err(USAGE.into()),
    }
    Ok(())
}

fn input() -> Result<SignedProbe, Box<dyn std::error::Error>> {
    let probe: SignedProbe = serde_json::from_str(&crate::agent::read_input(LIMIT)?)?;
    if !probe.report.valid() || !STANDARD.decode(&probe.signature).is_ok_and(|bytes| bytes.len() == 64) {
        return Err(Reason::InvalidProbe.message().into());
    }
    Ok(probe)
}

// The worker only handles the supplied fixture capture; no host or journal is contacted.
pub(crate) fn emit(mut output: impl Write) -> Result<(), Box<dyn std::error::Error>> {
    serde_json::to_writer(&mut output, &input()?)?;
    writeln!(output)?;
    Ok(())
}

pub(crate) fn record(
    authority: &Authority,
    journal: &mut Connection,
    probe: &SignedProbe,
    now: i64,
) -> Result<(), Box<dyn std::error::Error>> {
    authority.with_audited_policy(journal, |tx, workspace, policy, reference| {
        let worker = policy.workers.iter().find(|worker| worker.id == probe.report.worker_id)
            .ok_or(Reason::Uncommissioned.message())?;
        probe.verify(workspace, reference, worker).map_err(Reason::message)?;
        let at = probe.report.observed_ms;
        if at > now {
            return Err(Reason::InvalidProbe.message().into());
        }
        tx.execute(
            "INSERT INTO worker_hosts(workspace,policy_generation,worker_id,enrollment)
             VALUES (?1,?2,?3,?4) ON CONFLICT DO NOTHING",
            params![workspace, reference.generation, worker.id, serde_json::to_string(worker)?],
        )?;
        let serialized = serde_json::to_string(probe)?;
        tx.execute(
            "INSERT INTO worker_probes(workspace,policy_generation,worker_id,observed_ms,received_ms,signed_probe)
             VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT DO NOTHING",
            params![workspace, reference.generation, worker.id, at, now, serialized],
        )?;
        let matches: bool = tx.query_row(
            "SELECT signed_probe=?5 FROM worker_probes
             WHERE workspace=?1 AND policy_generation=?2 AND worker_id=?3 AND observed_ms=?4",
            params![workspace, reference.generation, worker.id, at, serialized],
            |row| row.get(0),
        )?;
        if !matches {
            return Err("A different worker probe is already recorded for this timestamp.".into());
        }
        Ok(())
    })
}

pub(in crate::machines) fn latest(
    db: &Connection,
    workspace: &str,
    reference: &PolicyRef,
    worker: &Enrollment,
) -> Result<Option<Report>, Reason> {
    let reading: Option<(i64, String)> = db.query_row(
        "SELECT observed_ms,signed_probe FROM worker_probes
         WHERE workspace=?1 AND policy_generation=?2 AND worker_id=?3 ORDER BY observed_ms DESC LIMIT 1",
        params![workspace, reference.generation, worker.id],
        |row| Ok((row.get(0)?,row.get(1)?)),
    ).optional().map_err(|_| Reason::EvidenceUnavailable)?;
    let Some((at, signed)) = reading else { return Ok(None) };
    let signed: SignedProbe = serde_json::from_str(&signed).map_err(|_| Reason::InvalidProbe)?;
    signed.verify(workspace, reference, worker)?;
    if signed.report.observed_ms != at {
        return Err(Reason::InvalidProbe);
    }
    Ok(Some(signed.report))
}

#[derive(Serialize)]
pub(in crate::machines) struct QuotaAccount {
    provider: Provider,
    account_ref: String,
    worker_ids: Vec<String>,
}

pub(in crate::machines) fn quota_accounts(workers: &[Enrollment]) -> Vec<QuotaAccount> {
    let mut accounts = BTreeMap::<_, Vec<_>>::new();
    for worker in workers {
        for (provider, account) in &worker.accounts {
            accounts.entry((*provider, account)).or_default().push(worker.id.clone());
        }
    }
    accounts.into_iter().map(|((provider, account_ref), mut worker_ids)| {
        worker_ids.sort_unstable();
        QuotaAccount { provider, account_ref: account_ref.clone(), worker_ids }
    }).collect()
}
