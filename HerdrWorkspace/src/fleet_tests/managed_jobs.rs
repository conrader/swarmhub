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
                        "machine.exec" => {
                            let p = &request["params"];
                            assert_eq!(p["on"], "mini-m4");
                            assert_eq!(p["cwd"], "/");
                            assert_eq!(p["timeout"], 3);
                            assert!(p["line"].is_null());
                            let argv = p["argv"].as_array().unwrap();
                            assert_eq!(argv[..4], [json!(PROGRAM), json!("job-worker"), json!("rpc"), json!(STATE_DIR)]);
                            assert_eq!(argv.len(), 6);
                            let verb = argv[4].as_str().unwrap().to_owned();
                            let payload = argv[5].as_str().unwrap().to_owned();
                            let (incompatible, lose_reply, timeout, drop_start) = {
                                let mut transport = shared.lock().unwrap();
                                transport.calls.push(verb.clone());
                                (transport.incompatible, verb == "start" && transport.lose_start,
                                    verb == "start" && transport.timeout_start, verb == "start" && transport.drop_before_start)
                            };
                            if drop_start {
                                return;
                            }
                            let mut view = tokio::task::spawn_blocking(move || {
                                run_worker(&root, &verb, &payload)
                            }).await.unwrap();
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

fn run_worker(root: &Path, verb: &str, payload: &str) -> Value {
    // Regular files prevent an inherited writer from holding the test's EOF.
    let mut stdout = tempfile::tempfile().unwrap();
    let mut stderr = tempfile::tempfile().unwrap();
    let status = rpc_command(root, verb, payload)
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
        worker.inputs.enrollment.fixture_runtime_profiles.insert(provider, "local".into());
        worker.inputs.republish(vec![]);
        fake_profile(&worker, if provider == Provider::Claude { "claude" } else { "codex" }, outcome, 30_000);
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
        let mut f = Fixture::new(provider, "success");
        {
            let mut transport = f.remote.state.lock().unwrap();
            transport.lose_start = provider == Provider::Claude;
            transport.timeout_start = provider == Provider::Codex;
        }
        let pause = f.worker.pause("before-child-registration");
        let id = f.submit("one-start", provider).await;
        assert_eq!(status(&f.bridge, &id).status, "queued");
        assert_eq!(f.remote.calls("start"), 0);
        jobs::poll(&f.bridge).await;
        assert_eq!(status(&f.bridge, &id).status, "unknown");
        assert_eq!(status(&f.bridge, &id).worker_reason.as_deref(), Some("worker_reply_lost"));
        assert_eq!(event_count(&f.bridge, &id), 0);
        let child = f.worker.checkpoint("before-child-registration");
        assert!(live(&child));
        f.ordinary.agents(vec![]);
        f.listener.abort();
        let _ = (&mut f.listener).await;
        let worker_core = f.bridge.worker_core.take();
        let offline = workspace(f.temp.path(), reopen_journal(&f.temp.path().join("offline-placeholder")));
        drop(std::mem::replace(&mut f.bridge, offline));
        let mut restarted = workspace(f.temp.path(), reopen_journal(&f.temp.path().join("journal")));
        restarted.worker_core = worker_core;
        restarted.fleet_policy = Ok(Some(authority(&f.worker.inputs)));
        // The fake Core lost every start reply and there is no callback path.
        // Release the detached child with both the requesting session and bridge off.
        fs::remove_file(pause).unwrap();
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
        assert_eq!(saved.status, "exited");
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
    assert_eq!(status(&f.bridge, &id).worker_reason.as_deref(), Some("unknown_attempt"));
    assert_eq!(f.remote.calls("start"), 1);
    assert_eq!(event_count(&f.bridge, &id), 0);
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
