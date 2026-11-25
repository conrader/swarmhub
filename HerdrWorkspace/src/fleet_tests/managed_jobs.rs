use super::{
    WAIT, detached_attempts::{FIXTURE_BRIEF, Worker, fake_profile},
    job_delivery::{FakeCore, drain, session, terminal, workspace},
    jobs_fixture::{self, OWNER}, reopen_journal,
};
use crate::{
    Core, Workspace, bots::{self, Ask}, helpers::{self, Action},
    job_worker::{bridge::{PROGRAM, STATE_DIR}, tests::{authority, live, rpc_command}},
    jobs::{self, Command, JobStatus, Submit},
    machines::probe::Provider,
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use rusqlite::params;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::DirBuilderExt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{io::{AsyncBufReadExt, AsyncWriteExt, BufReader}, net::UnixListener, task::JoinHandle};

#[derive(Default)]
struct Transport {
    offline: bool,
    incompatible: bool,
    lose_start: bool,
    timeout_start: bool,
    drop_before_start: bool,
    calls: Vec<String>,
    collected: Vec<Value>,
}

struct WorkerCore {
    socket: PathBuf,
    state: Arc<Mutex<Transport>>,
    task: JoinHandle<()>,
}

impl WorkerCore {
    fn spawn(path: &Path, worker: &Worker) -> Self {
        let protected = path.join("p");
        fs::DirBuilder::new().mode(0o700).create(&protected).unwrap();
        let socket = protected.join("worker.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let state = Arc::new(Mutex::new(Transport::default()));
        let shared = state.clone();
        let root = worker.root.clone();
        let target = worker.inputs.enrollment.fixture_worker_target.clone().unwrap();
        let task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let (root, target, shared) = (root.clone(), target.clone(), shared.clone());
                tokio::spawn(async move {
                    let mut stream = BufReader::new(stream);
                    let mut input = String::new();
                    stream.read_line(&mut input).await.unwrap();
                    let request: Value = serde_json::from_str(&input).unwrap();
                    let result = match request["method"].as_str().unwrap() {
                        "machine.list" => {
                            let online = !shared.lock().unwrap().offline;
                            json!({"machines":[{"name":"mini-m4","target":target,
                                "state": if online { "connected" } else { "unreachable" }}]})
                        }
                        "fixture.machine.exec_stdin" => {
                            let p = &request["params"];
                            assert_eq!(p["on"], "mini-m4");
                            assert_eq!(p["cwd"], "/");
                            assert_eq!(p["timeout"], 3);
                            assert!(p["line"].is_null());
                            let argv = p["argv"].as_array().unwrap();
                            assert_eq!(argv[..4], [json!(PROGRAM), json!("job-worker"), json!("rpc"), json!(STATE_DIR)]);
                            assert_eq!(argv.len(), 5);
                            let verb = argv[4].as_str().unwrap().to_owned();
                            let payload = STANDARD.decode(p["stdin"].as_str().unwrap()).unwrap();
                            let (incompatible, lose_reply, timeout, drop_start) = {
                                let mut transport = shared.lock().unwrap();
                                transport.calls.push(verb.clone());
                                (transport.incompatible, verb == "start" && transport.lose_start,
                                    verb == "start" && transport.timeout_start, verb == "start" && transport.drop_before_start)
                            };
                            if drop_start {
                                return;
                            }
                            let worker_verb = verb.clone();
                            let mut view = tokio::task::spawn_blocking(move || {
                                run_worker(&root, &worker_verb, &payload)
                            }).await.unwrap();
                            if verb == "collect" {
                                shared.lock().unwrap().collected.push(view.clone());
                            }
                            if lose_reply {
                                return;
                            }
                            if incompatible {
                                view["protocol"] = 1.into();
                            }
                            json!({"code":if timeout {None} else {Some(0)},
                                "stdout":if timeout { String::new() } else { STANDARD.encode(view.to_string()) },
                                "stderr":"","truncated":false,"timed_out":timeout,"ms":1})
                        }
                        method => panic!("Unexpected worker Core method {method}"),
                    };
                    let response = json!({"jsonrpc":"2.0","id":request["id"],"result":result});
                    let _ = stream.get_mut().write_all(format!("{response}\n").as_bytes()).await;
                });
            }
        });
        Self { socket, state, task }
    }

    fn calls(&self, verb: &str) -> usize {
        self.state.lock().unwrap().calls.iter().filter(|call| *call == verb).count()
    }
}

impl Drop for WorkerCore {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn run_worker(root: &Path, verb: &str, payload: &[u8]) -> Value {
    // Regular files prevent an inherited writer from holding the test's EOF.
    let mut stdout = tempfile::tempfile().unwrap();
    let mut stderr = tempfile::tempfile().unwrap();
    let mut stdin = tempfile::tempfile().unwrap();
    use std::io::Write;
    stdin.write_all(payload).unwrap();
    stdin.rewind().unwrap();
    let status = rpc_command(root, verb).stdin(stdin)
        .stdout(stdout.try_clone().unwrap()).stderr(stderr.try_clone().unwrap()).status().unwrap();
    use std::io::{Read, Seek};
    let mut bytes = String::new();
    stdout.rewind().unwrap();
    stdout.read_to_string(&mut bytes).unwrap();
    if !status.success() {
        let mut diagnostics = String::new();
        stderr.rewind().unwrap();
        stderr.read_to_string(&mut diagnostics).unwrap();
        panic!("Fixture worker failed {verb}: {bytes} {diagnostics}");
    }
    serde_json::from_str(bytes.lines().find(|line| line.starts_with('{')).unwrap()).unwrap()
}

struct Fixture {
    temp: tempfile::TempDir,
    worker: Worker,
    bridge: Workspace,
    ordinary: FakeCore,
    remote: WorkerCore,
    owner: Value,
    spool: PathBuf,
    listener: JoinHandle<()>,
}

impl Fixture {
    fn new(provider: Provider, outcome: &str) -> Self {
        let temp = tempfile::tempdir().unwrap();
        let mut worker = Worker::new(temp.path(), "placeholder", 1);
        worker.inputs.enrollment.fixture_worker_target = Some("worker@mini-m4.invalid".into());
        if outcome == "review-evidence" {
            for (provider, name) in [(Provider::Codex, "codex"), (Provider::Claude, "claude")] {
                worker.inputs.enrollment.fixture_runtime_profiles.insert(provider, name.into());
                fake_profile(&worker, name, outcome, 30_000);
            }
        } else {
            worker.inputs.enrollment.fixture_runtime_profiles.insert(provider, "local".into());
            fake_profile(&worker, if provider == Provider::Claude { "claude" } else { "codex" }, outcome, 30_000);
        }
        worker.inputs.republish(vec![]);
        let mut bridge = workspace(temp.path(), jobs_fixture::journal(&temp.path().join("journal")));
        let ordinary = FakeCore::start(&bridge.core.0);
        let remote = WorkerCore::spawn(temp.path(), &worker);
        bridge.worker_core = Some(Core(remote.socket.clone()));
        bridge.fleet_policy = Ok(Some(authority(&worker.inputs)));
        let pin = &worker.inputs.enrollment.projects[0];
        bridge.history.db().unwrap().execute(
            "INSERT INTO projects(id,name,machine,folder,note,created_ms) VALUES (?1,'fixture','mini-m4',?2,'',?3)",
            params![pin.id, pin.folder, pin.created_ms],
        ).unwrap();
        let owner = session(&bridge.history, OWNER, "t1", 1, "idle");
        bots::noted(&bridge.history, OWNER, key(&owner)).unwrap();
        assert!(crate::projects::grant_launch(&bridge.history, key(&owner), &[pin.id]).unwrap());
        ordinary.agents(vec![owner.clone()]);
        let spool = temp.path().join("spool");
        let listener = helpers::fixture::listen(bridge.clone(), spool.clone());
        Self { temp, worker, bridge, ordinary, remote, owner, spool, listener }
    }

    fn input(&self, provider: Provider) -> Submit {
        let pin = &self.worker.inputs.enrollment.projects[0];
        Submit {
            project: pin.id, workdir: pin.folder.clone(), brief: FIXTURE_BRIEF.into(), provider,
            profile: "local".into(), effort: Some("medium".into()),
            model: Some(if provider == Provider::Claude { "claude-opus-5" } else { "gpt-6.1-sol" }.into()),
        }
    }

    async fn submit(&self, key: &str, provider: Provider) -> String {
        self.submit_as(&self.owner, key, self.input(provider)).await.unwrap()["id"].as_str().unwrap().into()
    }

    async fn submit_as(&self, agent: &Value, submission_key: &str, input: Submit) -> Result<Value, String> {
        let reply = job(&self.spool, agent, Command::Submit { key: submission_key.into(), input }).await?;
        Ok(serde_json::from_str(&reply).unwrap())
    }

    fn invocations(&self) -> usize {
        fs::read_to_string(self.worker.root.join("fixture-runtimes/local/home/invocations"))
            .unwrap_or_default().lines().count()
    }

    async fn poll_until(&self, id: &str, expected: &str) -> JobStatus {
        tokio::time::timeout(WAIT, async {
            loop {
                jobs::poll(&self.bridge).await;
                let state = status(&self.bridge, id);
                if state.status == expected {
                    break state;
                }
                assert!(state.completion.is_none(), "{state:?}");
                tokio::time::sleep(Duration::from_millis(30)).await;
            }
        }).await.unwrap_or_else(|_| panic!("waiting for {expected}: {:?}", status(&self.bridge, id)))
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.listener.abort();
    }
}

fn key(agent: &Value) -> &str {
    agent["labels"]["swarmhub.launch"].as_str().unwrap()
}

async fn job(spool: &Path, agent: &Value, command: Command) -> Result<String, String> {
    helpers::fixture::ask(spool, key(agent), Action::Bot(Ask::Job { command: Box::new(command) })).await
}

fn status(w: &Workspace, id: &str) -> JobStatus {
    jobs::status(&w.history.db().unwrap(), id).unwrap().unwrap()
}

fn event_count(w: &Workspace, id: &str) -> i64 {
    w.history.db().unwrap().query_row(
        "SELECT count(*) FROM job_completions WHERE job_id=?1", [id], |r| r.get(0),
    ).unwrap()
}

#[tokio::test]
async fn gapplan_10_int_lost_start_closed_app_and_bridge_restart_recover_both_providers() {
    for provider in [Provider::Claude, Provider::Codex] {
        let mut f = Fixture::new(provider, "wait_for_release");
        {
            let mut transport = f.remote.state.lock().unwrap();
            transport.lose_start = provider == Provider::Claude;
            transport.timeout_start = provider == Provider::Codex;
        }
        let id = f.submit("one-start", provider).await;
        assert_eq!(status(&f.bridge, &id).status, "queued");
        assert_eq!(f.remote.calls("start"), 0);
        jobs::poll(&f.bridge).await;
        assert_eq!(status(&f.bridge, &id).status, "unknown");
        assert_eq!(status(&f.bridge, &id).worker_reason.as_deref(), Some("worker_reply_lost"));
        assert_eq!(event_count(&f.bridge, &id), 0);
        tokio::time::timeout(WAIT, async {
            while f.invocations() == 0 { tokio::time::sleep(Duration::from_millis(20)).await; }
        }).await.expect("the provider must start before disconnecting its owner");
        f.ordinary.agents(vec![]);
        f.listener.abort();
        let _ = (&mut f.listener).await;
        let worker_core = f.bridge.worker_core.take();
        let offline = workspace(f.temp.path(), reopen_journal(&f.temp.path().join("offline-placeholder")));
        drop(std::mem::replace(&mut f.bridge, offline));
        // The provider and its supervisor keep running while both clients are gone.
        fs::write(f.worker.root.join("fixture-runtimes/local/home/release"), b"").unwrap();
        let mut restarted = workspace(f.temp.path(), reopen_journal(&f.temp.path().join("journal")));
        restarted.worker_core = worker_core;
        restarted.fleet_policy = Ok(Some(authority(&f.worker.inputs)));
        let scheduler = jobs::start_serving(restarted.clone());
        let saved = tokio::time::timeout(WAIT, async {
            loop {
                let state = status(&restarted, &id);
                if state.completion.is_some() {
                    break state;
                }
                tokio::time::sleep(Duration::from_millis(30)).await;
            }
        }).await.unwrap();
        scheduler.abort();
        f.bridge = restarted;
        assert_eq!(saved.status, "exited", "{saved:?}; provider invocations: {}", f.invocations());
        assert_eq!(saved.completion.unwrap().exit.code, Some(0));
        assert_eq!(saved.review_eligible, Some(provider == Provider::Claude));
        let observed = saved.observed_runtime.unwrap();
        let account = f.worker.inputs.enrollment.accounts.get(&provider).unwrap();
        assert_eq!(observed.account_ref.as_ref(), Some(account));
        assert_eq!(observed.model.as_deref(), (provider == Provider::Claude).then_some("claude-sonnet-5"));
        assert_eq!(f.invocations(), 1);
        assert_eq!(f.remote.calls("start"), 1);
        assert_eq!(event_count(&f.bridge, &id), 1);

        let replacement = session(&f.bridge.history, OWNER, "t2", 2, "idle");
        bots::noted(&f.bridge.history, OWNER, key(&replacement)).unwrap();
        f.ordinary.agents(vec![replacement.clone()]);
        f.listener = helpers::fixture::listen(f.bridge.clone(), f.temp.path().join("spool-restarted"));
        f.spool = f.temp.path().join("spool-restarted");
        let result = job(&f.spool, &replacement, Command::Result { id: id.clone(), reference: "result".into() }).await.unwrap();
        assert_eq!(result, if provider == Provider::Claude { "Claude fixture result" } else { "Codex fixture result\n" });
        assert!(job(&f.spool, &replacement, Command::Result { id: id.clone(), reference: "../result".into() }).await.is_err());
        assert_eq!(f.remote.calls("result"), 1);
        let late = job(&f.spool, &replacement, Command::Cancel { id: id.clone() }).await.unwrap();
        assert_eq!(serde_json::from_str::<Value>(&late).unwrap()["status"], "exited");
        assert_eq!(f.remote.calls("cancel"), 0);
        drain(&f.bridge).await;
        assert_eq!(f.ordinary.writes().len(), 1);
        let event = format!("{id}:1");
        assert!(f.ordinary.writes()[0]["text"].as_str().unwrap().contains(&event));
        let ack = || helpers::fixture::ask(&f.spool, key(&replacement), Action::Bot(Ask::CompletionAck { id: event.clone() }));
        let first = ack().await.unwrap();
        assert_eq!(first, ack().await.unwrap());
        drain(&f.bridge).await;
        assert_eq!(f.ordinary.writes().len(), 1);
        assert_eq!(event_count(&f.bridge, &id), 1);
        let consumed: i64 = f.bridge.history.db().unwrap().query_row(
            "SELECT count(*) FROM job_deliveries WHERE job_id=?1 AND acknowledged_ms IS NOT NULL AND next_step_token IS NOT NULL",
            [&id], |row| row.get(0),
        ).unwrap();
        assert_eq!(consumed, 1);
    }
}

#[tokio::test]
async fn gapplan_10_int_delegated_job_waits_for_the_slot_and_recovers_after_cancel() {
    let f = Fixture::new(Provider::Codex, "first_holds");
    let first = f.submit("first", Provider::Codex).await;
    f.poll_until(&first, "running").await;
    tokio::time::timeout(WAIT, async {
        while f.invocations() != 1 {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }).await.unwrap();

    let (launch, helper_key) = f.bridge.history.start_launch("core", "fixture-helper", "delegate",
        None, "{}", "").unwrap().unwrap();
    f.bridge.history.db().unwrap().execute(
        "INSERT INTO helpers(launch,parent_key,name,difficulty,template,model)
         VALUES (?1,?2,'helper','easy','fixture','fixture')", params![launch, key(&f.owner)],
    ).unwrap();
    let helper = terminal("fixture-helper", &helper_key, "t3", 3, "idle");
    f.ordinary.agents(vec![f.owner.clone(), helper.clone()]);
    let second_reply = f.submit_as(&helper, "delegated", f.input(Provider::Codex)).await.unwrap();
    let second = second_reply["id"].as_str().unwrap();
    let queued = f.poll_until(second, "queued").await;
    assert_eq!(queued.worker_reason.as_deref(), Some("heavy_slots"));
    assert_eq!(queued.owner_bot_id, OWNER);
    assert_eq!(f.invocations(), 1);
    assert!(job(&f.spool, &helper, Command::Cancel { id: first.clone() }).await.is_err());

    let never_started = f.submit("cancel-pending", Provider::Codex).await;
    assert_eq!(f.poll_until(&never_started, "queued").await.worker_reason.as_deref(), Some("heavy_slots"));
    job(&f.spool, &f.owner, Command::Cancel { id: never_started.clone() }).await.unwrap();
    let pending_cancel = f.poll_until(&never_started, "cancelled").await;
    assert!(pending_cancel.observed_runtime.is_none());
    assert_eq!(f.invocations(), 1);

    let request = job(&f.spool, &f.owner, Command::Cancel { id: first.clone() }).await.unwrap();
    assert_eq!(serde_json::from_str::<Value>(&request).unwrap()["cancel_requested"], true);
    let cancelled = f.poll_until(&first, "cancelled").await;
    assert!(cancelled.completion.unwrap().exit.result.is_none());
    let finished = f.poll_until(second, "exited").await;
    assert_eq!(finished.owner_bot_id, OWNER);
    assert_eq!(f.invocations(), 2);
    assert_eq!(event_count(&f.bridge, &first), 1);
    assert_eq!(event_count(&f.bridge, second), 1);
    assert_eq!(event_count(&f.bridge, &never_started), 1);
}

#[tokio::test]
async fn gapplan_10_int_protocol_is_checked_and_missing_attempt_differs_from_unreachable_host() {
    let f = Fixture::new(Provider::Codex, "success");
    let id = f.submit("missing", Provider::Codex).await;
    f.remote.state.lock().unwrap().incompatible = true;
    jobs::poll(&f.bridge).await;
    assert_eq!(status(&f.bridge, &id).status, "queued");
    assert_eq!(status(&f.bridge, &id).worker_reason.as_deref(), Some("worker_incompatible"));
    assert_eq!(f.remote.calls("start"), 0);
    {
        let mut transport = f.remote.state.lock().unwrap();
        transport.incompatible = false;
        transport.drop_before_start = true;
    }
    jobs::poll(&f.bridge).await;
    assert_eq!(status(&f.bridge, &id).status, "unknown");
    f.remote.state.lock().unwrap().offline = true;
    jobs::poll(&f.bridge).await;
    assert_eq!(status(&f.bridge, &id).worker_reason.as_deref(), Some("host_unreachable"));
    f.remote.state.lock().unwrap().offline = false;
    jobs::poll(&f.bridge).await;
    assert_eq!(status(&f.bridge, &id).status, "interrupted");
    assert_eq!(status(&f.bridge, &id).worker_reason.as_deref(), Some("start_lost"));
    assert_eq!(f.remote.calls("start"), 1);
    assert_eq!(event_count(&f.bridge, &id), 1);
    assert_eq!(f.invocations(), 0);
}

#[tokio::test]
async fn gapplan_10_int_scope_conflicting_replay_and_project_worker_account_separation() {
    let f = Fixture::new(Provider::Claude, "success");
    let input = f.input(Provider::Claude);
    let first = f.submit_as(&f.owner, "duplicate", input.clone()).await.unwrap();
    assert_eq!(f.submit_as(&f.owner, "duplicate", input.clone()).await.unwrap(), first);
    let mut changed = input.clone();
    changed.brief.push_str(" changed");
    assert!(f.submit_as(&f.owner, "duplicate", changed).await.unwrap_err().contains("different job"));
    let mut outside = input.clone();
    outside.workdir = "/dev/shm/fixture".into();
    assert!(f.submit_as(&f.owner, "outside", outside).await.is_err());
    let mut unapproved = input.clone();
    unapproved.profile = "different".into();
    assert!(f.submit_as(&f.owner, "unapproved-profile", unapproved).await.is_err());

    let other_id = "other-job-owner";
    bots::register(&f.bridge.history.db().unwrap(), &bots::Registration {
        id: other_id.into(), name: Some("Other owner".into()), ..Default::default()
    }, 1).unwrap().unwrap();
    let other = session(&f.bridge.history, other_id, "t2", 2, "idle");
    bots::noted(&f.bridge.history, other_id, key(&other)).unwrap();
    f.ordinary.agents(vec![f.owner.clone(), other.clone()]);
    assert!(f.submit_as(&other, "duplicate", input).await.unwrap_err().contains("no grant"));
    let owned = job(&f.spool, &f.owner, Command::List).await.unwrap();
    let list: Value = serde_json::from_str(&owned).unwrap();
    assert_eq!(list.as_array().unwrap().len(), 1);
    assert_eq!(list[0]["id"], first["id"]);
    let id = first["id"].as_str().unwrap().to_owned();
    assert_eq!(job(&f.spool, &other, Command::List).await.unwrap(), "[]");
    assert!(job(&f.spool, &other, Command::Status { id: id.clone() }).await.is_err());
    assert!(job(&f.spool, &other, Command::Cancel { id: id.clone() }).await.is_err());
    assert!(job(&f.spool, &other, Command::Result { id, reference: "result".into() }).await.is_err());
    f.ordinary.machines(vec![json!({"name":"mini-m4","target":"worker@mini-m4.invalid","state":"connected"})]);
    let refused = helpers::fixture::ask(&f.spool, key(&f.owner), Action::Project(crate::projects::Ask::Run {
        project: "fixture".into(), command: vec![PROGRAM.into(), "status".into()], seconds: None,
    })).await.unwrap_err();
    assert!(refused.contains("protected worker account"));
    assert_eq!(f.remote.calls("start"), 0);
}


#[tokio::test]
async fn expired_reservation_reports_why_the_provider_did_not_start() {
    let f = Fixture::new(Provider::Claude, "success");
    let hold = f.worker.pause("before-child-registration");
    let id = f.submit("expired-before-start", Provider::Claude).await;
    jobs::poll(&f.bridge).await;
    f.worker.checkpoint("before-child-registration");
    assert_eq!(f.worker.db().execute("UPDATE leases SET expires_ms=heartbeat_ms", []).unwrap(), 1);
    fs::remove_file(hold).unwrap();
    let saved = f.poll_until(&id, "interrupted").await;
    assert_eq!(saved.worker_reason.as_deref(), Some("lease_expired"));
    assert_eq!(f.invocations(), 0);
    let event = bots::completions::status_for(&f.bridge.history.db().unwrap(), &id, 1).unwrap().unwrap();
    let item = serde_json::to_value(event).unwrap();
    assert_eq!(item["worker_reason"], "lease_expired");
    assert_eq!(item["outcome_detail"], "The worker’s reservation expired.");
    drain(&f.bridge).await;
    assert!(f.ordinary.writes().iter().any(|w| w["text"].as_str().is_some_and(|s| s.contains("lease_expired"))));
}

#[tokio::test]
async fn gapplan_10_int_reconciles_a_lost_supervisor_that_could_never_release_its_child() {
    let f = Fixture::new(Provider::Claude, "success");
    f.remote.state.lock().unwrap().lose_start = true;
    let hold = f.worker.pause("before-child-registration");
    let id = f.submit("supervisor-lost", Provider::Claude).await;
    jobs::poll(&f.bridge).await;
    assert_eq!(status(&f.bridge, &id).status, "unknown");
    let child = f.worker.checkpoint("before-child-registration");
    let (supervisor, pin): (String, Option<String>) = f.worker.db().query_row(
        "SELECT supervisor,child FROM attempts WHERE job_id=?1", [&id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap();
    assert!(pin.is_none());
    let supervisor: Value = serde_json::from_str(&supervisor).unwrap();
    let pid = supervisor["pid"].as_i64().unwrap() as i32;
    assert_eq!(unsafe { libc::kill(pid, libc::SIGKILL) }, 0);
    let settled = f.poll_until(&id, "interrupted").await;
    fs::remove_file(hold).unwrap();
    assert_eq!(settled.worker_reason.as_deref(), Some("supervisor_lost_before_child_pin"));
    assert_eq!(event_count(&f.bridge, &id), 1);
    assert_eq!(f.invocations(), 0);
    assert!(settled.completion.unwrap().exit.result.is_none());
    tokio::time::timeout(WAIT, async {
        while live(&child) {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }).await.unwrap();
    assert_eq!(f.remote.calls("start"), 1);
}

#[tokio::test]
async fn gapplan_11_int_cancel_missing_attempt_fences_even_a_delayed_start() {
    let f = Fixture::new(Provider::Codex, "success");
    let id = f.submit("cancel-missing", Provider::Codex).await;
    f.remote.state.lock().unwrap().drop_before_start = true;
    jobs::poll(&f.bridge).await;
    assert_eq!(status(&f.bridge, &id).status, "unknown");
    let pending = status(&f.bridge, &id);
    job(&f.spool, &f.owner, Command::Cancel { id: id.clone() }).await.unwrap();
    f.remote.state.lock().unwrap().drop_before_start = false;
    let cancelled = f.poll_until(&id, "cancelled").await;
    assert_eq!(cancelled.worker_reason.as_deref(), Some("missing_attempt_cancelled"));
    assert_eq!(event_count(&f.bridge, &id), 1);
    let input = f.input(Provider::Codex);
    let core = f.bridge.worker_core.as_ref().unwrap();
    let ticket = {
        let db = f.bridge.history.db().unwrap();
        let payload: String = db.query_row("SELECT payload_digest FROM jobs WHERE id=?1", [&id], |row| row.get(0)).unwrap();
        let policy = fleet_policy_for_fixture(&f);
        let project = crate::projects::one(&db, input.project).unwrap().unwrap();
        let placement = crate::projects::fixture_placement(&project, &policy, &input).unwrap();
        crate::job_worker::bridge::Ticket::new(&placement, &id, pending.attempt, OWNER, &input.submission(), &payload).unwrap()
    };
    let late = ticket.request(core, "mini-m4", crate::job_worker::bridge::Verb::Start, None).await.unwrap();
    assert_eq!(late.status, "cancelled");
    assert_eq!(f.invocations(), 0);
}

fn fleet_policy_for_fixture(f: &Fixture) -> crate::fleet_policy::Policy {
    authority(&f.worker.inputs).with_review_policy(Clone::clone).unwrap()
}

fn review_artifact(role: &str, manifest: &crate::parks::Manifest) -> Value {
    json!({
        "role": role,
        "revisions": {"code": manifest.artifact_pin, "apply": manifest.apply_pin, "reverse": manifest.reverse_pin},
        "tests": {"reference": "fixture-test-log", "digest": manifest.dry_run_ref, "passed": 3}
    })
}

fn reviewer(
    manifest: &crate::parks::Manifest, lineage: &str, round: i64, producer_digest: &str,
    verdict: &str, severity: Option<&str>,
) -> Value {
    let mut artifact = review_artifact("reviewer", manifest);
    artifact["lineage"] = json!(lineage);
    artifact["round"] = json!(round);
    artifact["producer_digest"] = json!(producer_digest);
    artifact["verdict"] = json!(verdict);
    artifact["findings"] = severity.map_or(json!([]), |severity| json!([{"severity":severity,"summary":"fixture finding"}]));
    artifact
}

async fn review_command(f: &Fixture, command: crate::job_reviews::Command) -> Result<Value, String> {
    review_command_as(f, &f.owner, command).await
}

async fn review_command_as(f: &Fixture, owner: &Value, command: crate::job_reviews::Command) -> Result<Value, String> {
    let reply = helpers::fixture::ask(&f.spool, key(owner), Action::Bot(Ask::JobReview { command: Box::new(command) })).await?;
    Ok(serde_json::from_str(&reply).unwrap())
}

fn review_input(f: &Fixture, provider: Provider, artifact: Value) -> Submit {
    let mut input = f.input(provider);
    input.profile = match provider { Provider::Claude => "claude", Provider::Codex => "codex" }.into();
    input.brief = artifact.to_string();
    input
}

async fn completed_review_job(f: &Fixture, key: &str, provider: Provider, artifact: Value) -> String {
    let job = f.submit_as(&f.owner, key, review_input(f, provider, artifact)).await.unwrap();
    job["id"].as_str().unwrap().into()
}

async fn record_completed(f: &Fixture, id: &str) -> Result<String, String> {
    record_completed_as(f, &f.owner, id).await
}

async fn record_completed_as(f: &Fixture, owner: &Value, id: &str) -> Result<String, String> {
    let completed = f.poll_until(id, "exited").await;
    assert_eq!(completed.review_eligible, Some(true));
    let result = completed.completion.unwrap().exit.result.unwrap();
    let artifact = job(&f.spool, owner, Command::Result { id: id.into(), reference: result.reference }).await.unwrap();
    review_command_as(f, owner, crate::job_reviews::Command::Record {
        job: id.into(), attempt: completed.attempt, artifact, same_provider_exception: None,
    }).await?;
    Ok(result.digest)
}

fn staging_manifest(f: &Fixture, git: &crate::parks::GitFixture) -> crate::parks::Manifest {
    let mut manifest = git.manifest.clone();
    manifest.owner = OWNER.into();
    manifest.project = f.input(Provider::Codex).project.to_string();
    manifest.dry_run_ref = "a".repeat(64);
    manifest
}

fn review_grant(manifest: &crate::parks::Manifest) -> crate::fleet_policy::Rule {
    let mut rule = crate::fleet_policy::tests::grant();
    rule.scope.action = Some(crate::parks::STAGING_ACTION.into());
    rule.scope.owner = Some(manifest.owner.clone());
    rule.scope.project = Some(manifest.project.clone());
    rule
}

async fn file_and_judge(f: &Fixture, manifest: &crate::parks::Manifest, name: &str) -> Value {
    use crate::{fleet_policy::{
        principals::{Principal, Purpose, Target},
        tests::{JARVIS, WORKSPACE, envelope},
    }, parks::{self, ParkRef}};
    let (_, jarvis) = super::fleet_authority::registered_launch(&f.bridge.history, JARVIS, "Jarvis");
    let ask = |launch, command| bots::answer(&f.bridge, Ok("core".into()), launch, Ask::Park { command: Box::new(command) });
    let filed: Value = serde_json::from_str(&ask(key(&f.owner), parks::Command::File {
        id: name.into(), manifest: Box::new(manifest.clone()),
    }).await.unwrap()).unwrap();
    let park = ParkRef { id: name.into(), manifest_digest: filed["manifest_digest"].as_str().unwrap().into() };
    let signed = f.worker.inputs.signing().sign_decision(envelope(
        WORKSPACE, Principal::Bot { id: JARVIS.into(), launch: jarvis.clone() }, Purpose::Execute,
        Target::Park { park: park.pin(manifest), policy: f.worker.inputs.reference.clone() }, "fixture-delegate-review",
    ));
    serde_json::from_str(&ask(&jarvis, parks::Command::Judge { park, signed }).await.unwrap()).unwrap()
}

#[tokio::test]
async fn gapplan_11_int_managed_sol_author_sonnet_review_jarvis_and_git_readback() {
    use crate::parks::{GitFixture, Service};
    let mut f = Fixture::new(Provider::Codex, "review-evidence");
    let git = GitFixture::new(f.temp.path());
    let mut manifest = staging_manifest(&f, &git);
    f.worker.inputs.republish(vec![review_grant(&manifest)]);
    let lineage = completed_review_job(&f, "author", Provider::Codex, review_artifact("author", &manifest)).await;
    let producer_digest = record_completed(&f, &lineage).await.unwrap();
    manifest.review_ref = lineage.clone();
    f.bridge.parks = Service::fixture(&git.directory, manifest.clone());

    // A same-family job and changed artifact bytes cannot establish a review.
    let review = reviewer(&manifest, &lineage, 0, &producer_digest, "pass", None);
    let same_family = completed_review_job(&f, "same-family", Provider::Codex, review.clone()).await;
    assert!(record_completed(&f, &same_family).await.unwrap_err().contains("different observed model family"));
    let reviewer = completed_review_job(&f, "independent-review", Provider::Claude, review).await;
    let review_digest = record_completed(&f, &reviewer).await.unwrap();
    assert!(review_command(&f, crate::job_reviews::Command::Record {
        job: reviewer, attempt: 1, artifact: "PASS".into(), same_provider_exception: None,
    }).await.is_err());
    let inspected = review_command(&f, crate::job_reviews::Command::Status { lineage: lineage.clone() }).await.unwrap();
    assert_eq!(inspected["producer"]["runtime"]["family"], "codex");
    assert_eq!(inspected["producer"]["runtime"]["model"], "gpt-6.1-sol");
    assert_eq!(inspected["review"]["runtime"]["family"], "claude");
    assert_eq!(inspected["review"]["runtime"]["model"], "claude-sonnet-5");
    assert_eq!(inspected["review"]["runtime"]["effort"], "high");

    let result = file_and_judge(&f, &manifest, "reviewed-effect").await;
    assert_eq!(result["view"]["receipt"][0], "verified");
    assert_eq!(result["view"]["receipt"][1]["after_apply"]["revision"], manifest.expected_postcondition);
    assert_eq!(git.head(), manifest.expected_postcondition);
    let db = f.bridge.history.db().unwrap();
    let audit: String = db.query_row("SELECT basis FROM park_decisions WHERE action='claim'", [], |row| row.get(0)).unwrap();
    let evidence: Value = serde_json::from_str(&audit).unwrap();
    assert_eq!(evidence["review"]["lineage"], lineage);
    assert_eq!(evidence["review"]["producer"], producer_digest);
    assert_eq!(evidence["review"]["review"], review_digest);
}

#[tokio::test]
async fn gapplan_11_int_competing_fixes_stale_final_reverse_and_revoked_p2_exception() {
    use crate::{fleet_policy::{self, ReviewPermission, RuleKind, tests::WORKSPACE},
        job_reviews::Command as Review, parks::{GitFixture, Service}};
    let mut f = Fixture::new(Provider::Codex, "review-evidence");
    let git = GitFixture::new(f.temp.path());
    let mut final_manifest = staging_manifest(&f, &git);
    let mut initial = final_manifest.clone();
    initial.artifact_pin = git.other.clone();
    initial.expected_postcondition = git.other.clone();
    let lineage = completed_review_job(&f, "author", Provider::Codex, review_artifact("author", &initial)).await;
    let digest = record_completed(&f, &lineage).await.unwrap();
    let reviewed = completed_review_job(&f, "r0", Provider::Claude,
        reviewer(&initial, &lineage, 0, &digest, "changes", Some("p1"))).await;
    record_completed(&f, &reviewed).await.unwrap();

    let request = |manifest: &crate::parks::Manifest, previous, alternative: bool| {
        let mut artifact = review_artifact("fixer", manifest);
        artifact["lineage"] = json!(lineage);
        artifact["round"] = json!(previous + 1);
        if alternative {
            artifact["tests"]["passed"] = 4.into();
        }
        Review::Fix { lineage: lineage.clone(), after_round: previous,
            input: review_input(&f, Provider::Codex, artifact), exception: None }
    };
    let (first, second) = tokio::join!(
        review_command(&f, request(&final_manifest, 0, false)),
        review_command(&f, request(&final_manifest, 0, true)),
    );
    assert_ne!(first.is_ok(), second.is_ok(), "{first:?}, {second:?}");
    let winner = first.is_ok();
    let fixed = first.or(second).unwrap();
    assert_eq!(review_command(&f, request(&final_manifest, 0, !winner)).await.unwrap(), fixed);
    let first_fix = fixed["job"]["id"].as_str().unwrap();
    let digest = record_completed(&f, first_fix).await.unwrap();
    let reviewed = completed_review_job(&f, "r1", Provider::Claude,
        reviewer(&final_manifest, &lineage, 1, &digest, "concerns", Some("p2"))).await;
    record_completed(&f, &reviewed).await.unwrap();

    let fixed = review_command(&f, request(&initial, 1, false)).await.unwrap();
    assert_eq!(fixed["round"], 2);
    let digest = record_completed(&f, fixed["job"]["id"].as_str().unwrap()).await.unwrap();
    final_manifest = initial;
    final_manifest.review_ref = lineage.clone();
    let mut stale = reviewer(&final_manifest, &lineage, 2, &digest, "pass", None);
    stale["revisions"]["reverse"] = json!("stale-reverse-wrapper");
    let stale = completed_review_job(&f, "stale-r2", Provider::Claude, stale).await;
    assert!(record_completed(&f, &stale).await.unwrap_err().contains("all three revision pins"));

    let final_review = reviewer(&final_manifest, &lineage, 2, &digest, "concerns", Some("p2"));
    let reviewed = completed_review_job(&f, "r2", Provider::Claude, final_review).await;
    record_completed(&f, &reviewed).await.unwrap();
    let mut third = review_artifact("fixer", &final_manifest);
    third["lineage"] = json!(lineage);
    third["round"] = json!(3);
    let extra = Review::Fix { lineage: lineage.clone(), after_round: 2,
        input: review_input(&f, Provider::Codex, third), exception: None };
    assert_eq!(review_command(&f, extra).await.unwrap(), json!({"status":"escalate","round":2}));
    let db = f.bridge.history.db().unwrap();
    let counts: (i64, i64) = db.query_row(
        "SELECT (SELECT count(*) FROM job_review_rounds WHERE lineage=?1 AND round>0),
                (SELECT count(*) FROM jobs WHERE submit_key LIKE 'review-fix:%')",
        [&lineage], |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap();
    assert_eq!(counts, (2, 2));
    drop(db);

    let restart = completed_review_job(&f, "restart-author", Provider::Codex,
        review_artifact("author", &final_manifest)).await;
    assert!(record_completed(&f, &restart).await.unwrap_err().contains("unresolved author lineage"));

    f.bridge.parks = Service::fixture(&git.directory, final_manifest.clone());
    let delegated = review_grant(&final_manifest);
    let mut exception = delegated.clone();
    exception.id = "residual-p2".into();
    exception.scope.principal = None;
    exception.effective_ms = crate::history::now() - 1000;
    exception.expires_ms = crate::history::now() + 60_000;
    exception.rule = RuleKind::ReviewException { lineage: lineage.clone(), permission: ReviewPermission::ResidualP2 };
    f.worker.inputs.republish(vec![delegated.clone(), exception.clone()]);

    // Revocation happens after the claim has recorded its evidence but before
    // the checked staging ref update executes.
    let mut revoked = fleet_policy::tests::policy(f.worker.inputs.reference.generation + 1, vec![delegated, exception]);
    revoked.workers.push(f.worker.inputs.enrollment.clone());
    revoked.revoked.insert("residual-p2".into());
    let publication = f.worker.inputs.signing().publication(revoked, WORKSPACE);
    let authority = authority(&f.worker.inputs);
    let publication = std::sync::Mutex::new(Some(publication));
    f.bridge.parks.after_claim = Some(Arc::new(move || {
        authority.publish_fixture(publication.lock().unwrap().take().unwrap()).unwrap();
    }));
    let result = file_and_judge(&f, &final_manifest, "review-revoked").await;
    assert_eq!(result, json!({"result":"held","reason":"authorization_changed"}));
    assert_eq!(git.head(), final_manifest.precondition);
    let db = f.bridge.history.db().unwrap();
    let (claim, count): (String, i64) = db.query_row(
        "SELECT basis,(SELECT count(*) FROM park_executions) FROM park_decisions WHERE action='claim'",
        [], |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap();
    let claim: Value = serde_json::from_str(&claim).unwrap();
    assert_eq!(claim["review"]["round"], 2);
    assert_eq!(claim["review"]["exceptions"][0]["id"], "residual-p2");
    assert_eq!(count, 0);
}

#[tokio::test]
async fn gapplan_13_int_denied_lineage_can_be_abandoned_and_owner_change_can_proceed() {
    use crate::{job_reviews::Command as Review, parks::{self, GitFixture}};
    let f = Fixture::new(Provider::Codex, "review-evidence");
    let git = GitFixture::new(f.temp.path());
    let mut manifest = staging_manifest(&f, &git);
    let author = review_artifact("author", &manifest);
    let lineage = completed_review_job(&f, "original-lineage", Provider::Codex, author.clone()).await;
    record_completed(&f, &lineage).await.unwrap();
    manifest.review_ref = lineage.clone();
    let parked = parks::file(&f.bridge.history.db().unwrap(), "denied-lineage", &manifest).unwrap();
    parks::decide(&mut f.bridge.history.db().unwrap(), &parked, parks::Decision {
        actor: "operator", source: parks::Source::Human, basis: "fixture denial",
    }, parks::Change::Deny).unwrap();

    let next = completed_review_job(&f, "same-owner", Provider::Codex, author.clone()).await;
    assert!(record_completed(&f, &next).await.unwrap_err().contains("unresolved author lineage"));
    let other_id = "replacement-owner";
    bots::register(&f.bridge.history.db().unwrap(), &bots::Registration {
        id: other_id.into(), name: Some("Replacement owner".into()), ..Default::default()
    }, 1).unwrap().unwrap();
    let other = session(&f.bridge.history, other_id, "t2", 2, "idle");
    bots::noted(&f.bridge.history, other_id, key(&other)).unwrap();
    assert!(crate::projects::grant_launch(&f.bridge.history, key(&other), &[f.input(Provider::Codex).project]).unwrap());
    f.ordinary.agents(vec![f.owner.clone(), other.clone()]);
    let other_job = f.submit_as(&other, "new-owner", review_input(&f, Provider::Codex, author)).await.unwrap();
    record_completed_as(&f, &other, other_job["id"].as_str().unwrap()).await.unwrap();
    let abandon = || Review::Abandon { lineage: lineage.clone(), reason: "Project direction changed".into() };
    assert!(review_command_as(&f, &other, abandon()).await.unwrap_err().contains("belongs to this owner"));
    for _ in 0..2 {
        let result = review_command(&f, abandon()).await.unwrap();
        assert_eq!(result["status"], "abandoned");
    }
    let inspected = review_command(&f, Review::Status { lineage: lineage.clone() }).await.unwrap();
    assert_eq!(inspected["closure"]["reason"], "Project direction changed");
    assert!(inspected["closure"]["at_ms"].as_i64().unwrap() > 0);
    record_completed(&f, &next).await.unwrap();
    let db = f.bridge.history.db().unwrap();
    let rows: (String, String) = db.query_row(
        "SELECT owner_bot_id,launch FROM job_review_closures WHERE lineage=?1",
        [&lineage], |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap();
    assert_eq!(rows, (OWNER.into(), key(&f.owner).into()));
    assert_eq!(parks::status(&db, &parked).unwrap(), parks::View::Status(parks::State::Denied));
    assert_eq!(git.head(), manifest.precondition);
}

#[tokio::test]
async fn gapplan_14_int_operator_can_close_a_lineage_without_its_owner() {
    use super::job_delivery::{AUTH, ORIGIN, TestApi};
    use crate::{
        fleet_policy::{principals::{Principal, Purpose, Target}, tests::{WORKSPACE, envelope}},
        parks::{self, GitFixture},
    };
    use reqwest::StatusCode;

    let f = Fixture::new(Provider::Codex, "review-evidence");
    let git = GitFixture::new(f.temp.path());
    let mut manifest = staging_manifest(&f, &git);
    let author = review_artifact("author", &manifest);
    let lineage = completed_review_job(&f, "operator-close-lineage", Provider::Codex, author.clone()).await;
    record_completed(&f, &lineage).await.unwrap();
    manifest.review_ref = lineage.clone();
    let park = parks::file(&f.bridge.history.db().unwrap(), "operator-close-park", &manifest).unwrap();
    let next = completed_review_job(&f, "after-close", Provider::Codex, author).await;
    let db = f.bridge.history.db().unwrap();
    db.execute("UPDATE bots SET noted_launch=NULL WHERE id=?1", [OWNER]).unwrap();
    db.execute("UPDATE parks SET state='reconciliation' WHERE id=?1", [&park.id]).unwrap();
    drop(db);

    let reason = "Project direction changed";
    let signed = f.worker.inputs.signing().sign_decision(envelope(
        WORKSPACE, Principal::Operator, Purpose::AbandonReview, Target::ReviewClosure {
            lineage: lineage.clone(), policy: f.worker.inputs.reference.clone(), reason: reason.into(),
        }, "operator-close-lineage",
    ));
    let api = TestApi::start(f.temp.path(), &f.bridge);
    let submit = |decision: Value| api.client.post(format!("{ORIGIN}/api/job-reviews/abandon"))
        .header("Origin", ORIGIN).bearer_auth(AUTH).header("Content-Type", "application/json")
        .body(decision.to_string());
    assert_eq!(submit(json!(signed)).send().await.unwrap().status(), StatusCode::CONFLICT);
    f.bridge.history.db().unwrap().execute(
        "UPDATE parks SET state='denied' WHERE id=?1", [&park.id],
    ).unwrap();
    let mut tampered = json!(signed);
    tampered["envelope"]["target"]["reason"] = json!("Edited after signing");
    assert_eq!(submit(tampered).send().await.unwrap().status(), StatusCode::FORBIDDEN);
    for _ in 0..2 {
        assert_eq!(submit(json!(signed)).send().await.unwrap().status(), StatusCode::OK);
    }
    {
        let db = f.bridge.history.db().unwrap();
        let (launch, stored): (String, String) = db.query_row(
            "SELECT launch,operator_decision FROM job_review_closures WHERE lineage=?1",
            [&lineage], |row| Ok((row.get(0)?, row.get(1)?)),
        ).unwrap();
        assert_eq!(launch, "operator");
        assert_eq!(serde_json::from_str::<Value>(&stored).unwrap(), json!(signed));
        assert_eq!(parks::status(&db, &park).unwrap(), parks::View::Status(parks::State::Denied));
    }
    bots::noted(&f.bridge.history, OWNER, key(&f.owner)).unwrap();
    record_completed(&f, &next).await.unwrap();
}

mod workload_grants;
