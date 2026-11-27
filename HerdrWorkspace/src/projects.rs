//! Projects: named folders on the other machines Herdr Core reaches (`machines`), and which agents may use them.
//!
//! The registry is two tables in the journal. An app keeps it through `/api/projects` and says per agent which
//! projects that agent may use: at launch (`projects` in `POST /api/agents`) and afterwards
//! (`/api/agents/{address}/{created_ms}/projects`). A helper uses the projects of the agent that started it.
//!
//! An agent works on a project with `swarmhub-herdr project …` (`cli`). That command only asks, over the same
//! socket and request files as `helper` (`helpers`), so it also works from Codex's sandbox. The workspace finds
//! the project among the asking agent's, and has Core run the command or touch the file in the project's folder
//! on its machine. The agent never names a host or a full path.
//!
//! This is bookkeeping, not isolation. Every agent runs as the workspace's account, and that account can reach
//! every machine added to Herdr Core. The list an agent gets decides what this command does for it, and nothing
//! else.

use crate::{
    Workspace,
    core::{self, Failure, Program},
    history::{History, StoreError, now},
};
use axum::{
    Json, Router,
    body::Bytes,
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;

pub(crate) mod cli;

/// Core machine aliases cannot contain spaces. Existing SSH aliases (including "local") keep their meaning.
pub(crate) const WORKSPACE_HOST: &str = "Workspace host";

fn core_target(machine: &str) -> Option<&str> {
    (machine != WORKSPACE_HOST).then_some(machine)
}

const NAME_SHAPE: &str = "Use 1–32 lowercase letters, digits, dots, dashes or underscores for a project's name, starting with a letter or digit.";
const FOLDER_SHAPE: &str = "Give the project's folder as a full path on its machine, such as /srv/shop, without `..` in it.";
const NOTE_SHAPE: &str = "Keep the note to 500 characters of plain text.";
const ADD_SHAPE: &str =
    "Send name, machine (a name from /api/machines) and folder, and note if you like.";
const CHANGE_SHAPE: &str = "Send any of name, machine, folder and note.";
const GRANT_SHAPE: &str = "Send projects: the ids of the projects this agent may use, at most 64.";
const UNKNOWN_PROJECT: &str = "One of these projects no longer exists. Load the projects again.";
pub(crate) const LAUNCH_SHAPE: &str =
    "For projects, send the ids of up to 64 projects that exist. Load the projects again.";
const NOTE_CHARS: usize = 500;
const MAX_GRANTS: usize = 64;
/// How long a machine may take to say whether a folder exists.
const CHECK_SECONDS: u64 = 20;

const RUN_SECONDS: u64 = 120;
/// Core's own ceiling for one program.
const MAX_RUN_SECONDS: u64 = 600;
const COMMAND_BYTES: usize = 32 * 1024;
/// What one answer carries of a command's standard output and standard error. More is cut in the middle.
const OUT_BYTES: usize = 96 * 1024;
const ERR_BYTES: usize = 24 * 1024;
const READ_LINES: usize = 2000;
const READ_BYTES: usize = 100 * 1024;
pub(crate) const WRITE_BYTES: usize = 128 * 1024;
const MAX_EDITS: usize = 32;

const NOT_AN_AGENT: &str = "This terminal is not a SwarmHub agent session, so it has no projects.";
const NO_PROJECTS: &str = "You have no assigned projects. The person who runs this workspace chooses them for each agent in SwarmHub; ask them if you need one.";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Project {
    id: i64,
    name: String,
    /// Herdr Core's name for the machine the folder is on.
    machine: String,
    folder: String,
    note: String,
    created_ms: i64,
}

impl Project {
    pub(crate) fn id(&self) -> i64 {
        self.id
    }

    pub(crate) fn name(&self) -> &str {
        &self.name
    }

    pub(crate) fn worker_pin<'a>(
        &self,
        worker: &'a crate::machines::probe::Enrollment,
    ) -> Option<&'a crate::machines::probe::ProjectPin> {
        worker.projects.iter().find(|pin| {
            self.machine.eq_ignore_ascii_case(&worker.machine)
                && pin.id == self.id
                && pin.created_ms == self.created_ms
                && pin.folder == self.folder
        })
    }
}

/// A project with its machine's connection as it is now.
#[derive(Serialize)]
struct View {
    #[serde(flatten)]
    project: Project,
    /// connecting, connected, needs_login, needs_update or unreachable as Core reports the machine; `missing`
    /// when Core has no machine by that name any more; `unknown` when Core could not be asked.
    machine_state: String,
    reachable: bool,
}

fn valid_name(name: &str) -> bool {
    core::valid_name(name) && name.as_bytes()[0].is_ascii_alphanumeric()
}

fn valid_folder(folder: &str) -> bool {
    folder.len() <= 1024
        && folder.starts_with('/')
        && !folder.chars().any(char::is_control)
        && !folder.split('/').any(|part| part == "..")
}

fn valid_note(note: &str) -> bool {
    note.chars().count() <= NOTE_CHARS && !note.chars().any(|c| c.is_control() && c != '\n')
}

/// A file's path inside a project's folder, as an agent gives it: relative, and never climbing out.
fn inside(path: &str) -> bool {
    (1..=1024).contains(&path.len())
        && !path.starts_with('/')
        && !path.starts_with('~')
        && !path.chars().any(char::is_control)
        && !path.split('/').any(|part| part == "..")
}

// ---- The registry.

fn read(row: &rusqlite::Row<'_>) -> rusqlite::Result<Project> {
    Ok(Project {
        id: row.get(0)?,
        name: row.get(1)?,
        machine: row.get(2)?,
        folder: row.get(3)?,
        note: row.get(4)?,
        created_ms: row.get(5)?,
    })
}

const COLUMNS: &str = "p.id,p.name,p.machine,p.folder,p.note,p.created_ms";

fn all(db: &Connection) -> rusqlite::Result<Vec<Project>> {
    db.prepare(&format!("SELECT {COLUMNS} FROM projects p ORDER BY p.name"))?
        .query_map([], read)?
        .collect()
}

pub(crate) fn one(db: &Connection, id: i64) -> rusqlite::Result<Option<Project>> {
    db.query_row(
        &format!("SELECT {COLUMNS} FROM projects p WHERE p.id=?1"),
        [id],
        read,
    )
    .optional()
}

/// The projects the agent with this launch key may use. A helper has those of the agent that started it.
fn granted(db: &Connection, key: &str) -> rusqlite::Result<Vec<Project>> {
    db.prepare(&format!(
        "SELECT {COLUMNS} FROM projects p JOIN agent_projects a ON a.project=p.id
         WHERE a.launch_key=COALESCE(
            (SELECT h.parent_key FROM helpers h JOIN journal j ON j.id=h.launch WHERE j.launch_key=?1), ?1)
         ORDER BY p.name"
    ))?
    .query_map([key], read)?
    .collect()
}

pub(crate) fn can_use(db: &Connection, key: &str, project: i64) -> rusqlite::Result<bool> {
    Ok(granted(db, key)?.iter().any(|candidate| candidate.id == project))
}

pub(crate) fn fixture_placement(
    project: &Project, policy: &crate::fleet_policy::Policy, input: &crate::jobs::Submit,
) -> Option<crate::job_worker::bridge::Placement> {
    let (worker, pin) = policy.workers.iter()
        .find_map(|worker| project.worker_pin(worker).map(|pin| (worker, pin)))?;
    let provider = input.provider;
    if crate::machines::probe::admission::heavy_capability(worker).is_err()
        || pin.folder != input.workdir
        || std::path::Path::new(&pin.folder).starts_with("/dev/shm")
        || pin.requirements.provider.is_some_and(|required| required != provider)
        || worker.fixture_runtime_profiles.get(&provider) != Some(&input.profile)
    {
        return None;
    }
    Some(crate::job_worker::bridge::Placement {
        host_id: worker.id.clone(),
        fingerprint: worker.fingerprint(),
        machine: worker.machine.clone(),
        target: worker.fixture_worker_target.clone()?,
        project_created_ms: pin.created_ms,
        provider,
        account_ref: worker.accounts.get(&provider)?.clone(),
        profile: input.profile.clone(),
    })
}

fn is_helper(db: &Connection, key: &str) -> rusqlite::Result<bool> {
    db.query_row(
        "SELECT EXISTS(SELECT 1 FROM helpers h JOIN journal j ON j.id=h.launch WHERE j.launch_key=?1)",
        [key],
        |row| row.get(0),
    )
}

/// Makes `ids` the projects of the agent with this launch key. `false`, and no change, when one of them is not a
/// project.
fn grant(db: &mut Connection, key: &str, ids: &[i64]) -> rusqlite::Result<bool> {
    let change = db.transaction()?;
    change.execute("DELETE FROM agent_projects WHERE launch_key=?1", [key])?;
    for id in ids {
        let known = change.execute(
            "INSERT OR IGNORE INTO agent_projects (launch_key, project)
             SELECT ?1, id FROM projects WHERE id=?2",
            params![key, id],
        )?;
        if known == 0 && one(&change, *id)?.is_none() {
            return Ok(false);
        }
    }
    change.commit()?;
    Ok(true)
}

/// The names of the projects on each machine, for the machine list.
pub(crate) fn names_by_machine(
    history: &History,
) -> Result<HashMap<String, Vec<String>>, StoreError> {
    Ok(by_machine(&*history.db()?, false)?.into_iter().map(|(machine, projects)| {
        (machine, projects.into_iter().map(|project| project.name).collect())
    }).collect())
}

pub(crate) fn by_machine(db: &Connection, ignore_case: bool) -> Result<HashMap<String, Vec<Project>>, StoreError> {
    let mut found = HashMap::<_, Vec<_>>::new();
    for project in all(db)? {
        let name = if ignore_case { project.machine.to_ascii_lowercase() } else { project.machine.clone() };
        found.entry(name).or_default().push(project);
    }
    Ok(found)
}

/// The projects a launch request names, before anything is started. `None` when there are too many or one of
/// them does not exist (`LAUNCH_SHAPE`).
pub(crate) fn wanted(history: &History, ids: &[i64]) -> Result<Option<Vec<Project>>, StoreError> {
    if ids.len() > MAX_GRANTS {
        return Ok(None);
    }
    let db = history.db()?;
    let mut projects = Vec::new();
    for id in ids {
        match one(&db, *id)? {
            Some(project) => projects.push(project),
            None => return Ok(None),
        }
    }
    Ok(Some(projects))
}

/// Records the projects of a launch that is about to start.
pub(crate) fn grant_launch(history: &History, key: &str, ids: &[i64]) -> Result<bool, StoreError> {
    Ok(grant(&mut *history.db()?, key, ids)?)
}

/// One sentence for a new agent's first task: which projects it has and where to learn the rest.
pub(crate) fn launch_hint(projects: &[Project]) -> Option<String> {
    if projects.is_empty() {
        return None;
    }
    let names: Vec<String> = projects
        .iter()
        .map(|project| format!("{} (on {})", project.name, project.machine))
        .collect();
    Some(format!(
        "You may work on these projects: {}. Run `swarmhub-herdr project list` to see them and how to run commands and edit files there.",
        names.join(", ")
    ))
}

// ---- For apps.

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/projects", get(list).post(add))
        .route("/api/projects/{id}", post(change))
        .route("/api/projects/{id}/remove", post(remove))
        .route(
            "/api/agents/{id}/{created}/projects",
            get(agent_projects).post(set_agent_projects),
        )
}

/// An answer that ends a request early. Boxed: a response is large beside what the same calls return when all
/// is well.
type Refusal = Box<Response>;

fn refusal(status: StatusCode, kind: &str, error: &str) -> Refusal {
    Box::new((status, Json(json!({ "error": error, "kind": kind }))).into_response())
}

fn invalid(shape: &str) -> Refusal {
    refusal(StatusCode::UNPROCESSABLE_ENTITY, "invalid", shape)
}

fn storage<T>(_: T) -> Refusal {
    Box::new(StoreError.into_response())
}

fn core_trouble(failure: Failure) -> Refusal {
    Box::new(failure.into_response())
}

fn gone() -> Refusal {
    refusal(
        StatusCode::NOT_FOUND,
        "project_unknown",
        "This project no longer exists. Load the projects again.",
    )
}

fn name_taken(name: &str) -> Refusal {
    refusal(
        StatusCode::CONFLICT,
        "name_taken",
        &format!("There is already a project named {name}."),
    )
}

fn answered(result: Result<Response, Refusal>) -> Response {
    result.unwrap_or_else(|refusal| *refusal)
}

/// The state of every machine Core has, by name; `None` when Core could not be asked.
async fn machine_states(w: &Workspace) -> Option<HashMap<String, String>> {
    Some(
        w.core
            .machines()
            .await
            .ok()?
            .into_iter()
            .map(|machine| (machine.name, machine.state))
            .chain(std::iter::once((WORKSPACE_HOST.to_owned(), "connected".to_owned())))
            .collect(),
    )
}

fn views(projects: Vec<Project>, states: Option<&HashMap<String, String>>) -> Vec<View> {
    projects
        .into_iter()
        .map(|project| {
            let machine_state = match states {
                None => "unknown".to_owned(),
                Some(states) => states
                    .get(&project.machine)
                    .cloned()
                    .unwrap_or_else(|| "missing".to_owned()),
            };
            View {
                reachable: machine_state == "connected",
                machine_state,
                project,
            }
        })
        .collect()
}

/// `projects` with their machines' states. Core is asked only when there is a project to say it for.
async fn shown(w: &Workspace, projects: Vec<Project>) -> Vec<View> {
    let states = if projects.is_empty() {
        Some(HashMap::new())
    } else {
        machine_states(w).await
    };
    views(projects, states.as_ref())
}

async fn listed(w: &Workspace) -> Result<Vec<View>, Refusal> {
    let projects = all(&*w.history.db().map_err(storage)?).map_err(storage)?;
    Ok(shown(w, projects).await)
}

async fn list(State(w): State<Workspace>) -> Response {
    answered(
        listed(&w)
            .await
            .map(|projects| Json(json!({ "projects": projects })).into_response()),
    )
}

/// Whether `folder` is a folder on `machine` now, by asking that machine.
async fn check_folder(w: &Workspace, machine: &str, folder: &str) -> Result<(), Refusal> {
    let unreachable = |why: &str| {
        refusal(
            StatusCode::CONFLICT,
            "machine_unreachable",
            &format!(
                "{machine} is not reachable now ({why}), so the folder could not be checked. Nothing was saved."
            ),
        )
    };
    if let Some(machine) = core_target(machine) {
        let machines = w.core.machines().await.map_err(core_trouble)?;
        let Some(found) = machines.iter().find(|known| known.name == machine) else {
            return Err(refusal(
                StatusCode::UNPROCESSABLE_ENTITY,
                "machine_unknown",
                &format!("Herdr has no machine named {machine}. Add the server first."),
            ));
        };
        if found.state != "connected" {
            return Err(unreachable(&found.state));
        }
    }
    let failed = |why: &str| {
        refusal(
            StatusCode::BAD_GATEWAY,
            "check_failed",
            &format!("{machine} could not say whether {folder} exists{why}. Nothing was saved."),
        )
    };
    let argv = ["test".to_owned(), "-d".to_owned(), folder.to_owned()];
    match w
        .core
        .run_on(core_target(machine), "/", Program::Argv(&argv), CHECK_SECONDS)
        .await
    {
        Ok(ran) if ran.code == Some(0) => Ok(()),
        Ok(ran) if ran.code == Some(1) && !ran.timed_out => Err(refusal(
            StatusCode::UNPROCESSABLE_ENTITY,
            "folder_missing",
            &format!("There is no folder {folder} on {machine}. Nothing was saved."),
        )),
        Ok(_) => Err(failed("")),
        Err(Failure::Rejected(kind, message))
            if matches!(kind.as_str(), "unavailable" | "machine_unknown") =>
        {
            Err(unreachable(&message))
        }
        Err(Failure::Rejected(_, message)) => Err(failed(&format!(": {message}"))),
        Err(failure) => Err(core_trouble(failure)),
    }
}

fn checked(project: &Project, shape: &'static str) -> Result<(), Refusal> {
    for (fits, shape) in [
        (valid_name(&project.name), NAME_SHAPE),
        (valid_folder(&project.folder), FOLDER_SHAPE),
        (valid_note(&project.note), NOTE_SHAPE),
        (project.machine == WORKSPACE_HOST || core::valid_name(&project.machine), shape),
    ] {
        if !fits {
            return Err(invalid(shape));
        }
    }
    Ok(())
}

async fn add(State(w): State<Workspace>, body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        name: String,
        machine: String,
        folder: String,
        #[serde(default)]
        note: String,
    }
    let added = async {
        let wanted: Wanted = serde_json::from_slice(&body).map_err(|_| invalid(ADD_SHAPE))?;
        let project = Project {
            id: 0,
            name: wanted.name,
            machine: wanted.machine,
            folder: wanted.folder,
            note: wanted.note.trim().to_owned(),
            created_ms: now(),
        };
        checked(&project, ADD_SHAPE)?;
        check_folder(&w, &project.machine, &project.folder).await?;
        let saved = w
            .history
            .db()
            .map_err(storage)?
            .query_row(
                &format!(
                    "INSERT INTO projects (name, machine, folder, note, created_ms)
                     SELECT ?1, ?2, ?3, ?4, ?5 WHERE NOT EXISTS (SELECT 1 FROM projects WHERE name=?1)
                     RETURNING {}",
                    COLUMNS.replace("p.", "")
                ),
                params![
                    project.name,
                    project.machine,
                    project.folder,
                    project.note,
                    project.created_ms
                ],
                read,
            )
            .optional()
            .map_err(storage)?
            .ok_or_else(|| name_taken(&project.name))?;
        let project = shown(&w, vec![saved]).await.remove(0);
        Ok((StatusCode::CREATED, Json(json!({ "project": project }))).into_response())
    };
    answered(added.await)
}

async fn change(State(w): State<Workspace>, Path(id): Path<i64>, body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        name: Option<String>,
        machine: Option<String>,
        folder: Option<String>,
        note: Option<String>,
    }
    let changed = async {
        let wanted: Wanted = serde_json::from_slice(&body).map_err(|_| invalid(CHANGE_SHAPE))?;
        let before = one(&*w.history.db().map_err(storage)?, id)
            .map_err(storage)?
            .ok_or_else(gone)?;
        let after = Project {
            name: wanted.name.unwrap_or_else(|| before.name.clone()),
            machine: wanted.machine.unwrap_or_else(|| before.machine.clone()),
            folder: wanted.folder.unwrap_or_else(|| before.folder.clone()),
            note: wanted
                .note
                .map_or_else(|| before.note.clone(), |note| note.trim().to_owned()),
            ..before.clone()
        };
        checked(&after, CHANGE_SHAPE)?;
        // A new name or note needs no machine; a new place is checked like a new project's.
        if after.machine != before.machine || after.folder != before.folder {
            check_folder(&w, &after.machine, &after.folder).await?;
        }
        {
            let db = w.history.db().map_err(storage)?;
            let saved = db
                .execute(
                    "UPDATE projects SET name=?2, machine=?3, folder=?4, note=?5 WHERE id=?1
                     AND NOT EXISTS (SELECT 1 FROM projects WHERE name=?2 AND id<>?1)",
                    params![id, after.name, after.machine, after.folder, after.note],
                )
                .map_err(storage)?;
            if saved == 0 {
                // Either it was removed meanwhile, or another project has the name.
                one(&db, id).map_err(storage)?.ok_or_else(gone)?;
                return Err(name_taken(&after.name));
            }
        }
        let project = shown(&w, vec![after]).await.remove(0);
        Ok(Json(json!({ "project": project })).into_response())
    };
    answered(changed.await)
}

/// Removes a project from the registry and from every agent's list. Nothing on its machine is touched.
async fn remove(State(w): State<Workspace>, Path(id): Path<i64>) -> Response {
    let removed = async {
        let removed = w
            .history
            .db()
            .map_err(storage)?
            .execute("DELETE FROM projects WHERE id=?1", [id])
            .map_err(storage)?;
        if removed == 0 {
            return Err(gone());
        }
        let projects = listed(&w).await?;
        Ok(Json(json!({ "removed": id, "projects": projects })).into_response())
    };
    answered(removed.await)
}

/// The launch key of a managed agent, and whether it is a helper.
async fn agent_key(w: &Workspace, id: &str, created: u64) -> Result<(String, bool), Refusal> {
    let core_id = w.core.identify().await.map_err(core_trouble)?.core.id;
    let key = crate::live_reply::launch_key(&w.history, &core_id, id, created)
        .map_err(storage)?
        .ok_or_else(|| core_trouble(Failure::Missing))?;
    let helper = is_helper(&*w.history.db().map_err(storage)?, &key).map_err(storage)?;
    Ok((key, helper))
}

async fn agent_view(w: &Workspace, key: &str, helper: bool) -> Result<Response, Refusal> {
    let projects = granted(&*w.history.db().map_err(storage)?, key).map_err(storage)?;
    Ok(Json(json!({
        "projects": shown(w, projects).await,
        // A helper's list is the list of the agent that started it, and is changed there.
        "inherited": helper,
    }))
    .into_response())
}

async fn agent_projects(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
) -> Response {
    let listed = async {
        let (key, helper) = agent_key(&w, &id, created).await?;
        agent_view(&w, &key, helper).await
    };
    answered(listed.await)
}

async fn set_agent_projects(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
    body: Bytes,
) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        projects: Vec<i64>,
    }
    let set = async {
        let wanted = serde_json::from_slice::<Wanted>(&body)
            .ok()
            .filter(|wanted| wanted.projects.len() <= MAX_GRANTS)
            .ok_or_else(|| invalid(GRANT_SHAPE))?;
        let (key, helper) = agent_key(&w, &id, created).await?;
        if helper {
            return Err(refusal(
                StatusCode::CONFLICT,
                "helper",
                "A helper uses the projects of the agent that started it. Change them there.",
            ));
        }
        if !grant(
            &mut *w.history.db().map_err(storage)?,
            &key,
            &wanted.projects,
        )
        .map_err(storage)?
        {
            return Err(refusal(
                StatusCode::UNPROCESSABLE_ENTITY,
                "project_unknown",
                UNKNOWN_PROJECT,
            ));
        }
        agent_view(&w, &key, false).await
    };
    answered(set.await)
}

// ---- For agents.

/// What `swarmhub-herdr project …` asks the workspace. A project is named as the registry names it.
#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, tag = "op", rename_all = "lowercase")]
pub(crate) enum Ask {
    List,
    Run {
        project: String,
        /// One word is a line for the machine's shell; several are a program and its arguments.
        command: Vec<String>,
        seconds: Option<u64>,
    },
    Read {
        project: String,
        path: String,
        offset: Option<usize>,
        limit: Option<usize>,
    },
    Write {
        project: String,
        path: String,
        text: String,
    },
    Edit {
        project: String,
        path: String,
        /// Pairs of the text that is there and the text that replaces it.
        edits: Vec<(String, String)>,
    },
}

/// The workspace's answer to an agent: what to print, and for a command its standard error and exit code.
#[derive(Default)]
pub(crate) struct Said {
    pub(crate) text: String,
    pub(crate) stderr: Option<String>,
    pub(crate) exit: Option<i32>,
}

impl Said {
    fn plain(text: String) -> Self {
        Self {
            text,
            ..Self::default()
        }
    }
}

/// Why Core did not do what an agent asked on `machine`, in words for the agent.
fn explain(failure: Failure, machine: &str) -> String {
    match failure {
        Failure::Unreachable => "Herdr Core is not reachable. Nothing was run or changed.".into(),
        Failure::Missing => "This agent session is no longer available.".into(),
        Failure::Input(message) => message.into(),
        Failure::Rejected(kind, message) => match kind.as_str() {
            "machine_unknown" => format!(
                "The machine {machine} of this project is no longer added to Herdr. Nothing was run or changed. Tell the user."
            ),
            "unavailable" => format!(
                "{machine} is not reachable right now ({message}). Nothing was run or changed. Try again in a minute, and tell the user if it stays that way."
            ),
            "needs_update" => format!(
                "Herdr's helper on {machine} is too old for this ({message}). Nothing was run or changed. Tell the user to run `hc machine update {machine}` on the Herdr server."
            ),
            _ => message,
        },
        Failure::Protocol | Failure::Uncertain => format!(
            "Herdr Core did not confirm this. It may or may not have happened on {machine}: look before you repeat it."
        ),
    }
}

/// Keeps the start and the end of text that is longer than `limit` bytes.
fn clip(text: String, limit: usize) -> (String, bool) {
    if text.len() <= limit {
        return (text, false);
    }
    let mut head = limit / 4;
    while !text.is_char_boundary(head) {
        head -= 1;
    }
    let mut tail = text.len() - (limit - limit / 4);
    while !text.is_char_boundary(tail) {
        tail += 1;
    }
    let cut = format!(
        "{}\n[… {} bytes left out here …]\n{}",
        &text[..head],
        tail - head,
        &text[tail..]
    );
    (cut, true)
}

/// Shrinks an answer until it fits the road back. It travels as JSON, where a byte that is not plain text can
/// take six times its room, so output full of such bytes is cut further.
fn fitted(mut said: Said) -> Said {
    const ROOM: usize = crate::helpers::REPLY_LIMIT - 8 * 1024;
    let room = |text: &str| serde_json::to_string(text).map_or(usize::MAX, |json| json.len());
    let mut limit = OUT_BYTES;
    while room(&said.text) + said.stderr.as_deref().map_or(0, room) > ROOM && limit > 512 {
        limit /= 2;
        said.text = clip(std::mem::take(&mut said.text), limit).0;
        said.stderr = said
            .stderr
            .take()
            .map(|err| clip(err, limit.min(ERR_BYTES)).0);
    }
    said
}

fn decoded(base64: &str) -> String {
    String::from_utf8_lossy(&STANDARD.decode(base64).unwrap_or_default()).into_owned()
}

fn list_text(projects: &[Project], states: Option<&HashMap<String, String>>) -> String {
    if projects.is_empty() {
        return NO_PROJECTS.into();
    }
    let mut text = String::from(
        "Your projects. Commands and file changes run in the folder on the host shown:\n",
    );
    for project in projects {
        let state = match states.map(|states| states.get(&project.machine)) {
            None => "state unknown".to_owned(),
            Some(None) => "this machine is no longer added to Herdr; tell the user".to_owned(),
            Some(Some(state)) => match state.as_str() {
                "connected" => "connected",
                "connecting" => "connecting now; try again in a moment",
                "needs_login" => "not reachable now: it refuses the login; tell the user",
                "needs_update" => {
                    "not reachable now: Herdr's helper there needs an update; tell the user"
                }
                _ => "not reachable now",
            }
            .to_owned(),
        };
        text.push_str(&format!(
            "  {}  on {}, folder {}  ({state})\n",
            project.name, project.machine, project.folder
        ));
        if !project.note.is_empty() {
            text.push_str(&format!("      {}\n", project.note.replace('\n', " ")));
        }
    }
    text.push_str(cli::HOW);
    text
}

/// Does what an agent's `project` command asks, for the agent with this launch key. `core_id` is the check that
/// the key belongs to a session of this workspace (`helpers::registered`).
pub(crate) async fn answer(
    w: &Workspace,
    core_id: Result<String, String>,
    key: &str,
    ask: Ask,
) -> Result<Said, String> {
    answer_whole(w, core_id, key, ask).await.map(fitted)
}

async fn ordinary_project_account(w: &Workspace, machine: &str) -> Result<(), String> {
    let target = w.core.machines().await.map_err(|failure| explain(failure, machine))?
        .into_iter().find(|item| item.name.eq_ignore_ascii_case(machine))
        .ok_or("The project's Core machine is unavailable.")?.target;
    let authority = w.fleet_policy.as_ref().ok().and_then(Option::as_ref)
        .ok_or("The worker account separation could not be verified.")?;
    let protected = authority.with_worker_policy(|_, _, policy, _| {
        policy.workers.iter().any(|worker| worker.fixture_worker_target.as_deref()
            .is_some_and(|worker| worker.eq_ignore_ascii_case(&target)))
    }).map_err(|_| "The worker account separation could not be verified.")?;
    if protected {
        return Err("This Core machine uses a protected worker account.".into());
    }
    Ok(())
}

async fn answer_whole(
    w: &Workspace,
    core_id: Result<String, String>,
    key: &str,
    ask: Ask,
) -> Result<Said, String> {
    core_id.map_err(|why| {
        if why == crate::helpers::UNREGISTERED {
            NOT_AN_AGENT.to_owned()
        } else {
            why
        }
    })?;
    const STORAGE: &str =
        "The workspace could not use its saved history. Nothing was run or changed.";
    let projects = w
        .history
        .db()
        .map_err(|_| STORAGE)
        .and_then(|db| granted(&db, key).map_err(|_| STORAGE))?;
    let find = |name: &str| {
        projects
            .iter()
            .find(|project| project.name == name)
            .ok_or_else(|| {
                let name: String = name.chars().take(40).collect();
                if projects.is_empty() {
                    format!("You have no project named {name:?}. {NO_PROJECTS}")
                } else {
                    let names: Vec<&str> = projects.iter().map(|p| p.name.as_str()).collect();
                    format!(
                        "You have no project named {name:?}. Yours: {}.",
                        names.join(", ")
                    )
                }
            })
    };
    if w.worker_core.is_some() {
        let project = match &ask {
            Ask::List => None,
            Ask::Run { project, .. } | Ask::Read { project, .. } | Ask::Write { project, .. }
            | Ask::Edit { project, .. } => Some(find(project)?),
        };
        if let Some(machine) = project.and_then(|p| core_target(&p.machine)) {
            ordinary_project_account(w, machine).await?;
        }
    }
    match ask {
        Ask::List => {
            let states = if projects.is_empty() {
                None
            } else {
                machine_states(w).await
            };
            Ok(Said::plain(list_text(&projects, states.as_ref())))
        }
        Ask::Run {
            project,
            command,
            seconds,
        } => {
            let project = find(&project)?;
            let size: usize = command.iter().map(String::len).sum();
            if command.is_empty()
                || command[0].trim().is_empty()
                || size > COMMAND_BYTES
                || command.iter().any(|word| word.contains('\0'))
            {
                return Err("Give a command of up to 32 KB after `--`.".into());
            }
            let seconds = seconds.unwrap_or(RUN_SECONDS).clamp(1, MAX_RUN_SECONDS);
            let program = match command.as_slice() {
                [line] => Program::Line(line),
                argv => Program::Argv(argv),
            };
            let ran = w
                .core
                .run_on(core_target(&project.machine), &project.folder, program, seconds)
                .await
                .map_err(|failure| match failure {
                    Failure::Rejected(kind, message) if kind == "spawn_failed" => format!(
                        "The command could not be started in {} on {}: {message}",
                        project.folder, project.machine
                    ),
                    failure => explain(failure, &project.machine),
                })?;
            let (out, out_cut) = clip(decoded(&ran.stdout), OUT_BYTES);
            let (mut err, err_cut) = clip(decoded(&ran.stderr), ERR_BYTES);
            let exit = match (ran.timed_out, ran.code, ran.signal) {
                (true, _, _) => 124,
                (false, Some(code), _) => code,
                (false, None, signal) => 128 + signal.unwrap_or(9),
            };
            if !err.is_empty() && !err.ends_with('\n') {
                err.push('\n');
            }
            err.push_str(&format!(
                "[project {} on {}: exit {exit} after {:.1} s",
                project.name,
                project.machine,
                ran.ms as f64 / 1000.0
            ));
            if ran.timed_out {
                err.push_str(&format!(
                    "; stopped at the {seconds} second limit, which --timeout raises up to {MAX_RUN_SECONDS}"
                ));
            }
            if ran.truncated || out_cut || err_cut {
                err.push_str("; the output was longer than one answer carries and was cut");
            }
            err.push(']');
            Ok(Said {
                text: out,
                stderr: Some(err),
                exit: Some(exit),
            })
        }
        Ask::Read {
            project,
            path,
            offset,
            limit,
        } => {
            let project = find(&project)?;
            if !inside(&path) {
                return Err(cli::PATH_SHAPE.into());
            }
            let lines = limit.unwrap_or(READ_LINES).clamp(1, READ_LINES);
            let file = w
                .core
                .read_on(
                    core_target(&project.machine),
                    &project.folder,
                    &path,
                    offset.filter(|line| *line > 0),
                    Some(lines),
                )
                .await
                .map_err(|failure| explain(failure, &project.machine))?;
            let mut text = file.text;
            let mut last = file.last;
            if text.len() > READ_BYTES {
                // Whole lines only: the next read continues after the last one given.
                let mut end = READ_BYTES;
                while !text.is_char_boundary(end) {
                    end -= 1;
                }
                let end = text[..end].rfind('\n').map_or(0, |at| at + 1);
                text.truncate(end);
                last = (file.first + text.lines().count()).saturating_sub(1);
                if text.is_empty() {
                    return Err(format!(
                        "Line {} of {path} is longer than one answer carries. Read it on the machine with `project run`, for example with cut or head -c.",
                        file.first
                    ));
                }
            }
            let note = if file.lines == 0 || last < file.first {
                format!(
                    "[{}:{path} has {} lines; none in this range]",
                    project.name, file.lines
                )
            } else if last < file.lines {
                format!(
                    "[{}:{path} lines {}–{last} of {}; continue with --offset {}]",
                    project.name,
                    file.first,
                    file.lines,
                    last + 1
                )
            } else {
                format!(
                    "[{}:{path} lines {}–{last} of {}]",
                    project.name, file.first, file.lines
                )
            };
            Ok(Said {
                text,
                stderr: Some(note),
                exit: None,
            })
        }
        Ask::Write {
            project,
            path,
            text,
        } => {
            let project = find(&project)?;
            if !inside(&path) {
                return Err(cli::PATH_SHAPE.into());
            }
            if text.len() > WRITE_BYTES {
                return Err(cli::WRITE_SHAPE.into());
            }
            let written = w
                .core
                .write_on(core_target(&project.machine), &project.folder, &path, &text)
                .await
                .map_err(|failure| explain(failure, &project.machine))?;
            Ok(Said::plain(format!(
                "Wrote {} bytes to {} on {}.",
                written.bytes, written.path, project.machine
            )))
        }
        Ask::Edit {
            project,
            path,
            edits,
        } => {
            let project = find(&project)?;
            if !inside(&path) {
                return Err(cli::PATH_SHAPE.into());
            }
            if edits.is_empty()
                || edits.len() > MAX_EDITS
                || edits.iter().any(|(old, _)| old.is_empty())
            {
                return Err(format!(
                    "Give 1 to {MAX_EDITS} pairs of --old TEXT and --new TEXT; an old text cannot be empty."
                ));
            }
            let written = w
                .core
                .edit_on(core_target(&project.machine), &project.folder, &path, &edits)
                .await
                .map_err(|failure| explain(failure, &project.machine))?;
            Ok(Said::plain(format!(
                "Edited {} on {}: {} replaced, {} bytes now.",
                written.path,
                project.machine,
                if edits.len() == 1 {
                    "1 text".to_owned()
                } else {
                    format!("{} texts", edits.len())
                },
                written.bytes
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn journal() -> (tempfile::TempDir, History) {
        let scratch = tempfile::tempdir().unwrap();
        let history = History::open_at(&scratch.path().join("workspace")).unwrap();
        (scratch, history)
    }

    fn project(db: &Connection, name: &str, machine: &str) -> i64 {
        db.query_row(
            "INSERT INTO projects (name, machine, folder, note, created_ms) VALUES (?1, ?2, '/srv/' || ?1, '', 1)
             RETURNING id",
            params![name, machine],
            |row| row.get(0),
        )
        .unwrap()
    }

    fn launch(history: &History, name: &str) -> (i64, String) {
        history
            .start_launch("core", name, "Start", None, "{}", "")
            .unwrap()
            .unwrap()
    }

    #[test]
    fn names_folders_notes_and_paths_are_checked() {
        for name in ["shop", "api-2", "a.b_c", "9lives"] {
            assert!(valid_name(name), "{name}");
        }
        for name in [
            "",
            "-shop",
            ".shop",
            "Shop",
            "my shop",
            "a/b",
            &"a".repeat(33),
        ] {
            assert!(!valid_name(name), "{name}");
        }
        for folder in ["/", "/srv/shop", "/home/me/my project", "/srv/shop/"] {
            assert!(valid_folder(folder), "{folder}");
        }
        for folder in [
            "",
            "srv/shop",
            "~/shop",
            "/srv/../etc",
            "/srv/shop\n",
            &format!("/{}", "a".repeat(1024)),
        ] {
            assert!(!valid_folder(folder), "{folder}");
        }
        assert!(valid_note("") && valid_note("Staging only.\nAsk before a deploy."));
        assert!(!valid_note("tab\there") && !valid_note(&"x".repeat(NOTE_CHARS + 1)));
        for path in ["a", "src/main.rs", "a b/c", ".env", "a/..b"] {
            assert!(inside(path), "{path}");
        }
        for path in [
            "",
            "/etc/passwd",
            "../x",
            "a/../../x",
            "~/x",
            "a\0b",
            &"a".repeat(1025),
        ] {
            assert!(!inside(path), "{path}");
        }
    }

    #[test]
    fn an_agent_has_the_projects_it_was_given_and_a_helper_those_of_its_parent() {
        let (_scratch, history) = journal();
        let (_, agent) = launch(&history, "agent");
        let (_, other) = launch(&history, "other");
        let (helper_row, helper) = launch(&history, "helper");
        let mut db = history.db().unwrap();
        db.execute(
            "INSERT INTO helpers (launch, parent_key, name, difficulty, template, model)
             VALUES (?1, ?2, 'easy-1', 'easy', 't', 'm')",
            params![helper_row, agent],
        )
        .unwrap();
        let shop = project(&db, "shop", "box");
        let api = project(&db, "api", "box");
        let names = |db: &Connection, key: &str| -> Vec<String> {
            granted(db, key)
                .unwrap()
                .into_iter()
                .map(|project| project.name)
                .collect()
        };
        assert!(names(&db, &agent).is_empty());
        assert!(grant(&mut db, &agent, &[shop, api, shop]).unwrap());
        assert_eq!(names(&db, &agent), ["api", "shop"]);
        assert_eq!(names(&db, &helper), ["api", "shop"]);
        assert!(names(&db, &other).is_empty());
        assert!(is_helper(&db, &helper).unwrap() && !is_helper(&db, &agent).unwrap());

        // A new list replaces the old one, and an unknown project changes nothing.
        assert!(grant(&mut db, &agent, &[api]).unwrap());
        assert_eq!(names(&db, &agent), ["api"]);
        assert!(!grant(&mut db, &agent, &[shop, 999]).unwrap());
        assert_eq!(names(&db, &agent), ["api"]);

        // Removing a project takes it from every agent's list.
        db.execute("DELETE FROM projects WHERE id=?1", [api])
            .unwrap();
        assert!(names(&db, &agent).is_empty() && names(&db, &helper).is_empty());
        assert!(grant(&mut db, &agent, &[]).unwrap());
        drop(db);
        assert_eq!(
            names_by_machine(&history).unwrap(),
            HashMap::from([("box".to_owned(), vec!["shop".to_owned()])])
        );
    }

    #[test]
    fn a_launch_names_only_projects_that_exist() {
        let (_scratch, history) = journal();
        let shop = project(&history.db().unwrap(), "shop", "box");
        let found = wanted(&history, &[shop]).unwrap().unwrap();
        assert_eq!(found[0].name, "shop");
        assert!(wanted(&history, &[]).unwrap().unwrap().is_empty());
        assert!(wanted(&history, &[shop, 77]).unwrap().is_none());
        assert!(
            wanted(&history, &vec![shop; MAX_GRANTS + 1])
                .unwrap()
                .is_none()
        );
        assert_eq!(launch_hint(&[]), None);
        let hint = launch_hint(&found).unwrap();
        assert!(hint.contains("shop (on box)") && hint.contains("swarmhub-herdr project list"));
        assert!(core::validate_task(&hint).is_ok());
    }

    #[test]
    fn views_say_how_each_projects_machine_is() {
        let (_scratch, history) = journal();
        let db = history.db().unwrap();
        project(&db, "shop", "box");
        project(&db, "api", "gone");
        project(&db, "docs", "down");
        let states = HashMap::from([
            ("box".to_owned(), "connected".to_owned()),
            ("down".to_owned(), "needs_login".to_owned()),
        ]);
        let shown = serde_json::to_value(views(all(&db).unwrap(), Some(&states))).unwrap();
        let state = |at: usize| {
            (
                shown[at]["name"].as_str().unwrap().to_owned(),
                shown[at]["machine_state"].as_str().unwrap().to_owned(),
                shown[at]["reachable"].as_bool().unwrap(),
            )
        };
        assert_eq!(state(0), ("api".into(), "missing".into(), false));
        assert_eq!(state(1), ("docs".into(), "needs_login".into(), false));
        assert_eq!(state(2), ("shop".into(), "connected".into(), true));
        assert_eq!(shown[2]["folder"], "/srv/shop");
        let unknown = serde_json::to_value(views(all(&db).unwrap(), None)).unwrap();
        assert_eq!(unknown[2]["machine_state"], "unknown");

        let text = list_text(&all(&db).unwrap(), Some(&states));
        assert!(text.contains("shop  on box, folder /srv/shop  (connected)"));
        assert!(text.contains("api  on gone") && text.contains("no longer added"));
        assert!(
            text.contains(
                "docs  on down, folder /srv/docs  (not reachable now: it refuses the login"
            )
        );
        assert_eq!(list_text(&[], None), NO_PROJECTS);
    }

    #[test]
    fn long_output_keeps_its_start_and_its_end() {
        assert_eq!(clip("short".into(), 10), ("short".into(), false));
        let long = format!("{}{}", "a".repeat(600), "ż".repeat(600));
        let (cut, was_cut) = clip(long.clone(), 400);
        assert!(was_cut && cut.starts_with(&"a".repeat(100)) && cut.ends_with(&"ż".repeat(100)));
        assert!(cut.contains("bytes left out here") && cut.len() < 500);
        assert_eq!(decoded("aGk="), "hi");
        assert_eq!(decoded("not base64"), "");

        // Bytes that JSON writes as six characters each: the answer is cut until it fits the road back.
        let said = fitted(Said {
            text: "\u{1}".repeat(OUT_BYTES),
            stderr: Some("\u{1}".repeat(ERR_BYTES)),
            exit: Some(0),
        });
        let sent = serde_json::to_string(&(&said.text, &said.stderr)).unwrap();
        assert!(sent.len() < crate::helpers::REPLY_LIMIT && said.text.len() >= OUT_BYTES / 8);
        assert!(said.text.contains("bytes left out here") && said.exit == Some(0));
        let plain = fitted(Said::plain("a".repeat(OUT_BYTES)));
        assert_eq!(plain.text.len(), OUT_BYTES);
    }

    #[test]
    fn an_ask_has_no_place_for_a_host_or_a_folder() {
        let run: Ask = serde_json::from_str(
            r#"{"op":"run","project":"shop","command":["make","test"],"seconds":null}"#,
        )
        .unwrap();
        assert!(matches!(run, Ask::Run { .. }));
        for refused in [
            r#"{"op":"run","project":"shop","command":["ls"],"seconds":null,"machine":"box"}"#,
            r#"{"op":"run","project":"shop","command":["ls"],"seconds":null,"cwd":"/"}"#,
            r#"{"op":"read","project":"shop","path":"a","offset":null,"limit":null,"on":"box"}"#,
            r#"{"op":"connect","project":"shop"}"#,
        ] {
            assert!(serde_json::from_str::<Ask>(refused).is_err(), "{refused}");
        }
        // Wrapped as the helper socket carries it.
        let line = serde_json::to_string(&crate::helpers::Action::Project(Ask::List)).unwrap();
        assert_eq!(line, r#"{"do":"project","op":"list"}"#);
        let back: crate::helpers::Action = serde_json::from_str(
            r#"{"do":"project","op":"edit","project":"shop","path":"a","edits":[["x","y"]]}"#,
        )
        .unwrap();
        assert_eq!(
            back,
            crate::helpers::Action::Project(Ask::Edit {
                project: "shop".into(),
                path: "a".into(),
                edits: vec![("x".into(), "y".into())],
            })
        );
    }
}
