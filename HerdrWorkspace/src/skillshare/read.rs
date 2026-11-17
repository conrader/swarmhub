//! What skillshare prints about the whole library, turned into what the workspace sends: the five kinds as one
//! list of items, and what its check for newer versions found. Nothing here runs a program or reads a file. The tests read answers captured from skillshare 0.30.8 (`fixtures`).

use super::parse::{MAX_NAME, MAX_PATH, MAX_TARGETS, Status, plain_path, printable, shortened};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// Items sent in one answer. `item_count` still counts them all.
pub(super) const MAX_ITEMS: usize = 1_000;
const MAX_SENTENCE: usize = 500;

/// The five kinds of things skillshare keeps.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum Kind {
    Skills,
    Agents,
    Mcp,
    Plugins,
    Hooks,
}

impl Kind {
    pub(super) const ALL: [Self; 5] = [
        Self::Skills,
        Self::Agents,
        Self::Mcp,
        Self::Plugins,
        Self::Hooks,
    ];

    pub(super) fn word(self) -> &'static str {
        match self {
            Self::Skills => "skills",
            Self::Agents => "agents",
            Self::Mcp => "mcp",
            Self::Plugins => "plugins",
            Self::Hooks => "hooks",
        }
    }

    /// The kind and the name in an item's id, such as `skills:group/nested`.
    pub(super) fn of(id: &str) -> Option<(Self, &str)> {
        let (kind, name) = id.split_once(':')?;
        let kind = Self::ALL.into_iter().find(|known| known.word() == kind)?;
        (!name.is_empty()).then_some((kind, name))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum State {
    /// A sync would change a Target.
    Waiting,
    /// The last check found a newer version where it came from.
    Update,
    InSync,
    Off,
    /// The reading that would say could not be made.
    Unknown,
}

/// What a sync would do for one item in one Target.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub(super) struct Waiting {
    pub target: String,
    pub action: String,
}

/// One thing in the library, of any kind.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub(super) struct Item {
    pub id: String,
    pub kind: Kind,
    /// The name skillshare lists it under.
    pub name: String,
    /// The last part of its path: what to call it on a screen.
    pub title: String,
    /// A skill's folder or an agent's file inside the source.
    pub path: Option<String>,
    pub description: Option<String>,
    pub state: State,
    pub enabled: bool,
    pub origin: Option<String>,
    pub source: Option<String>,
    pub version: Option<String>,
    /// The Targets it goes to.
    pub targets: Vec<String>,
    pub waiting: Vec<Waiting>,
    /// What the workspace will do for it: `enable`, `disable`, `update`, `uninstall`, `diff`.
    pub actions: Vec<&'static str>,
    /// What `skillshare update` takes for it: its own path, or the tracked checkout it lives in.
    #[serde(skip)]
    pub updates_as: Option<String>,
}

/// The message in the `{"error": "…"}` skillshare prints when a `--json` command fails.
pub(super) fn error(json: &str) -> Option<String> {
    let value: Value = serde_json::from_str(json.trim()).ok()?;
    let message = value.as_object()?.get("error")?.as_str()?.trim();
    (!message.is_empty()).then(|| sentence(message))
}

pub(super) fn sentence(text: &str) -> String {
    let clean: String = text
        .chars()
        .filter(|character| !character.is_control() || *character == '\n')
        .collect();
    shortened(clean.trim(), MAX_SENTENCE)
}

pub(super) fn named(text: Option<String>, limit: usize) -> Option<String> {
    text.filter(|text| printable(text, limit))
}

/// One line of `skillshare list --all --json`.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub(super) struct Listed {
    pub name: String,
    kind: Option<String>,
    #[serde(rename = "relPath")]
    pub path: String,
    #[serde(default)]
    pub disabled: bool,
    source: Option<String>,
    #[serde(rename = "type")]
    installed_as: Option<String>,
    #[serde(rename = "repoName")]
    repo: Option<String>,
}

impl Listed {
    pub(super) fn kind(&self) -> Kind {
        if self.kind.as_deref() == Some("agent") {
            Kind::Agents
        } else {
            Kind::Skills
        }
    }

    pub(super) fn id(&self) -> String {
        format!("{}:{}", self.kind().word(), self.path)
    }

    /// The path without an agent file's ending: what `update` and `uninstall` take.
    pub(super) fn bare(&self) -> &str {
        match self.kind() {
            Kind::Agents => self.path.strip_suffix(".md").unwrap_or(&self.path),
            _ => &self.path,
        }
    }

    /// It lives in a Git checkout skillshare updates as a whole.
    pub(super) fn tracked(&self) -> Option<&str> {
        self.repo.as_deref()
    }
}

/// The skills and agents in `skillshare list --all --json`, in its order. `None` when the text is not that list.
pub(super) fn listed(json: &str) -> Option<Vec<Listed>> {
    let listed: Vec<Listed> = serde_json::from_str(json).ok()?;
    Some(
        listed
            .into_iter()
            .filter(|entry| printable(&entry.name, MAX_NAME) && printable(&entry.path, MAX_PATH))
            .map(|entry| Listed {
                source: named(entry.source, MAX_PATH),
                installed_as: named(entry.installed_as, 40),
                repo: named(entry.repo, MAX_NAME),
                ..entry
            })
            .collect(),
    )
}

/// What `skillshare diff --json` says a sync would do: the Targets it names, and each skill or agent that waits.
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct Drift {
    pub targets: Vec<String>,
    /// The kind, the name without an agent file's ending, and what waits where.
    pub waits: Vec<(Kind, String, Waiting)>,
}

pub(super) fn drift(json: &str) -> Option<Drift> {
    #[derive(Deserialize)]
    struct Report {
        targets: Vec<Target>,
    }
    #[derive(Deserialize)]
    struct Target {
        name: String,
        #[serde(default)]
        items: Vec<Entry>,
    }
    #[derive(Deserialize)]
    struct Entry {
        name: String,
        kind: Option<String>,
        #[serde(default)]
        action: String,
        #[serde(default)]
        is_sync: bool,
    }
    let report: Report = serde_json::from_str(json).ok()?;
    let mut drift = Drift::default();
    for target in report.targets.into_iter().take(MAX_TARGETS) {
        if !printable(&target.name, MAX_NAME) {
            continue;
        }
        for entry in target.items {
            // What a sync would not touch, such as a folder of the Target's own, does not wait.
            if !entry.is_sync || !printable(&entry.name, MAX_PATH) {
                continue;
            }
            let (kind, name) = if entry.kind.as_deref() == Some("agent") {
                let name = entry.name.strip_suffix(".md").unwrap_or(&entry.name);
                (Kind::Agents, name.to_owned())
            } else {
                (Kind::Skills, entry.name)
            };
            let action = named(Some(entry.action), 40).unwrap_or_else(|| "change".into());
            drift.waits.push((
                kind,
                name,
                Waiting {
                    target: target.name.clone(),
                    action,
                },
            ));
        }
        drift.targets.push(target.name);
    }
    Some(drift)
}

/// One line of a plan for MCP servers or hooks: what a sync would do for `name` in `target`.
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(default)]
pub(super) struct Change {
    pub target: String,
    pub name: String,
    pub action: String,
    message: Option<String>,
    root: Option<String>,
}

impl Change {
    fn usable(&self) -> bool {
        (self.target.is_empty() || printable(&self.target, MAX_NAME))
            && (self.name.is_empty() || printable(&self.name, MAX_NAME))
            && self.action.len() <= 40
    }

    fn waits(&self) -> bool {
        !matches!(self.action.as_str(), "" | "unchanged" | "inactive")
    }

    fn waiting(&self) -> Waiting {
        Waiting {
            target: self.target.clone(),
            action: self.action.clone(),
        }
    }
}

/// `skillshare mcp list --json`: where the servers are written down, and what a sync would do for each.
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct Mcp {
    /// The file the servers are kept in: skillshare's configuration, or the one it names under `sources.mcp`.
    pub file: Option<String>,
    pub blocked: bool,
    pub changes: Vec<Change>,
}

pub(super) fn mcp(json: &str) -> Option<Mcp> {
    #[derive(Deserialize)]
    struct Plan {
        #[serde(rename = "sourcePath")]
        file: Option<String>,
        #[serde(default)]
        blocked: bool,
        changes: Vec<Change>,
    }
    let plan: Plan = serde_json::from_str(json).ok()?;
    Some(Mcp {
        file: named(plan.file, 4_096),
        blocked: plan.blocked,
        changes: plan
            .changes
            .into_iter()
            .filter(Change::usable)
            .take(MAX_ITEMS * 4)
            .collect(),
    })
}

/// One plugin in `skillshare plugin list --json`, and the agent programs it is bound to.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Plugin {
    pub name: String,
    pub source: Option<String>,
    pub version: Option<String>,
    /// The agent program, whether something still waits there, and the version it has.
    pub bindings: Vec<(String, bool, Option<String>)>,
}

pub(super) fn plugins(json: &str) -> Option<Vec<Plugin>> {
    #[derive(Deserialize)]
    struct Report {
        packages: BTreeMap<String, Package>,
    }
    #[derive(Default, Deserialize)]
    #[serde(default)]
    struct Package {
        version: Option<String>,
        source: Option<String>,
        bindings: BTreeMap<String, Binding>,
    }
    #[derive(Default, Deserialize)]
    #[serde(default)]
    struct Binding {
        id: Option<String>,
        version: Option<String>,
        sync: Option<bool>,
        pending: Option<String>,
    }
    let report: Report = serde_json::from_str(json).ok()?;
    Some(
        report
            .packages
            .into_iter()
            .filter(|(name, _)| printable(name, MAX_NAME))
            .map(|(name, package)| {
                let first = package.bindings.values().next();
                let source = named(package.source.clone(), MAX_PATH)
                    .or_else(|| named(first.and_then(|binding| binding.id.clone()), MAX_PATH));
                let version = named(package.version.clone(), 80)
                    .or_else(|| named(first.and_then(|binding| binding.version.clone()), 80));
                Plugin {
                    name,
                    source: source.map(|source| safe_url(&source)),
                    version,
                    bindings: package
                        .bindings
                        .into_iter()
                        .filter(|(target, _)| printable(target, MAX_NAME))
                        .take(MAX_TARGETS)
                        .map(|(target, binding)| {
                            let waits = binding.pending.is_some_and(|pending| !pending.is_empty())
                                || binding.sync == Some(false);
                            (target, waits, named(binding.version, 80))
                        })
                        .collect(),
                }
            })
            .collect(),
    )
}

/// One hook entry in `skillshare hooks list --json`.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Hook {
    pub name: String,
    pub description: Option<String>,
    pub enabled: bool,
    /// It is written down in the source. A hook that only waits to be cleaned out of an agent program is not.
    pub declared: bool,
    /// Each agent program it is bound to, with the events it listens to there.
    pub agents: Vec<(String, Vec<String>)>,
    pub changes: Vec<Change>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct Hooks {
    pub entries: Vec<Hook>,
    /// skillshare said what a sync would do. Without that, whether a hook waits is unknown.
    pub planned: bool,
    /// Why skillshare would refuse to sync, when it would.
    pub blocked: Option<String>,
}

pub(super) fn hooks(json: &str) -> Option<Hooks> {
    #[derive(Deserialize)]
    struct Report {
        source: Source,
        plan: Option<Plan>,
    }
    #[derive(Default, Deserialize)]
    #[serde(default)]
    struct Source {
        entries: BTreeMap<String, Entry>,
    }
    #[derive(Default, Deserialize)]
    #[serde(default)]
    struct Entry {
        description: Option<String>,
        enabled: Option<bool>,
        bindings: BTreeMap<String, Binding>,
    }
    #[derive(Default, Deserialize)]
    #[serde(default)]
    struct Binding {
        events: BTreeMap<String, Value>,
    }
    #[derive(Default, Deserialize)]
    #[serde(default)]
    struct Plan {
        blocked: bool,
        changes: Vec<Change>,
    }
    let report: Report = serde_json::from_str(json).ok()?;
    let mut entries: Vec<Hook> = report
        .source
        .entries
        .into_iter()
        .filter(|(name, _)| printable(name, MAX_NAME))
        .map(|(name, entry)| Hook {
            name,
            description: entry
                .description
                .map(|text| sentence(&text))
                .filter(|text| !text.is_empty()),
            enabled: entry.enabled != Some(false),
            declared: true,
            agents: entry
                .bindings
                .into_iter()
                .filter(|(agent, _)| printable(agent, MAX_NAME))
                .take(MAX_TARGETS)
                .map(|(agent, binding)| {
                    let events = binding
                        .events
                        .into_keys()
                        .filter(|event| printable(event, 80))
                        .take(40)
                        .collect();
                    (agent, events)
                })
                .collect(),
            changes: Vec::new(),
        })
        .collect();
    let planned = report.plan.is_some();
    let plan = report.plan.unwrap_or_default();
    let mut conflict = None;
    for change in plan.changes.into_iter().filter(Change::usable) {
        if change.action == "conflict" && conflict.is_none() {
            conflict = Some(change.message.as_deref().map(sentence).unwrap_or_default());
        }
        // A hook of one project root in a configuration for several: not one of this library's own entries.
        if change.name.is_empty() || change.root.as_deref().is_some_and(|root| !root.is_empty()) {
            continue;
        }
        let at = match entries.iter().position(|hook| hook.name == change.name) {
            Some(at) => at,
            None => {
                entries.push(Hook {
                    name: change.name.clone(),
                    description: None,
                    enabled: true,
                    declared: false,
                    agents: Vec::new(),
                    changes: Vec::new(),
                });
                entries.len() - 1
            }
        };
        entries[at].changes.push(change);
    }
    let blocked = (plan.blocked || conflict.is_some()).then(|| {
        let why = conflict.unwrap_or_default();
        if why.is_empty() {
            "A hook conflicts with one an agent program already has.".to_owned()
        } else {
            format!("A hook conflicts with one an agent program already has: {why}")
        }
    });
    Some(Hooks {
        entries,
        planned,
        blocked,
    })
}

/// What the last `skillshare check` found: the skills, agents and tracked checkouts with something newer where
/// they came from, and the version each checked skill has now.
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct Updates {
    /// When the check ran, in seconds since 1970.
    pub at: u64,
    pub skills: BTreeSet<String>,
    pub agents: BTreeSet<String>,
    pub repos: BTreeSet<String>,
    pub versions: BTreeMap<String, String>,
}

impl Updates {
    pub(super) fn count(&self) -> usize {
        self.skills.len() + self.agents.len() + self.repos.len()
    }
}

/// `skillshare check --json`, added to `updates`. `None` when the text is not that report.
pub(super) fn checked(json: &str, updates: &mut Updates) -> Option<()> {
    #[derive(Deserialize)]
    struct Report {
        #[serde(default)]
        tracked_repos: Vec<Entry>,
        skills: Vec<Entry>,
    }
    #[derive(Deserialize)]
    struct Entry {
        name: String,
        #[serde(default)]
        status: String,
        version: Option<String>,
    }
    let report: Report = serde_json::from_str(json).ok()?;
    for repo in report.tracked_repos {
        if repo.status == "behind" && printable(&repo.name, MAX_NAME) {
            updates.repos.insert(repo.name);
        }
    }
    for skill in report.skills {
        if !printable(&skill.name, MAX_PATH) {
            continue;
        }
        if let Some(version) = named(skill.version, 80) {
            updates.versions.insert(skill.name.clone(), version);
        }
        if skill.status == "update_available" {
            updates.skills.insert(skill.name);
        }
    }
    Some(())
}

/// `skillshare check agents --json`, added to `updates`.
pub(super) fn checked_agents(json: &str, updates: &mut Updates) -> Option<()> {
    #[derive(Deserialize)]
    struct Entry {
        name: String,
        #[serde(default)]
        status: String,
    }
    let agents: Vec<Entry> = serde_json::from_str(json).ok()?;
    for agent in agents {
        if agent.status == "update_available" && printable(&agent.name, MAX_PATH) {
            updates.agents.insert(agent.name);
        }
    }
    Some(())
}

/// Everything read about one library. A part that could not be read is `None`.
#[derive(Default)]
pub(super) struct Parts {
    pub status: Option<Status>,
    pub listed: Option<Vec<Listed>>,
    pub drift: Option<Drift>,
    pub mcp: Option<Mcp>,
    pub plugins: Option<Vec<Plugin>>,
    pub hooks: Option<Hooks>,
}

/// A source address for a screen: no scheme, no `.git`, and never a password.
pub(super) fn safe_url(address: &str) -> String {
    let (scheme, rest) = match address.split_once("://") {
        Some((scheme, rest)) => (Some(scheme), rest),
        None => (None, address),
    };
    // What is before an `@` in the host part is a sign-in. `git@host:path` keeps its user, which is no secret.
    let host_end = rest.find('/').unwrap_or(rest.len());
    let rest = match rest[..host_end].rfind('@') {
        Some(at) if scheme.is_some() => &rest[at + 1..],
        _ => rest,
    };
    let rest = rest.split(['?', '#']).next().unwrap_or(rest);
    let rest = rest.trim_end_matches('/');
    let rest = rest
        .strip_suffix(".git")
        .unwrap_or(rest)
        .replace(".git//", "/");
    match scheme {
        Some("http" | "https") | None => rest,
        Some(scheme) => format!("{scheme}://{rest}"),
    }
}

/// The library as one list: every skill and agent skillshare lists, then MCP servers, plugins and hooks by name.
pub(super) fn items(parts: &Parts, updates: Option<&Updates>) -> Vec<Item> {
    let mut items = Vec::new();
    let status = parts.status.as_ref();
    let skill_targets: Vec<String> = status
        .map(|status| {
            status
                .targets
                .iter()
                .filter(|target| target.skills_enabled)
                .map(|target| target.name.clone())
                .collect()
        })
        .unwrap_or_default();
    let agent_targets = status
        .map(|status| status.agent_targets.clone())
        .unwrap_or_default();
    for entry in parts.listed.iter().flatten() {
        let kind = entry.kind();
        let waiting: Vec<Waiting> = parts
            .drift
            .iter()
            .flat_map(|drift| &drift.waits)
            .filter(|(waits, name, _)| {
                *waits == kind && (name == &entry.name || name == entry.bare())
            })
            .map(|(_, _, waiting)| waiting.clone())
            .collect();
        let has_update = updates.is_some_and(|updates| {
            let found = |names: &BTreeSet<String>| {
                names.contains(entry.bare()) || names.contains(&entry.name)
            };
            match kind {
                Kind::Agents => found(&updates.agents),
                _ => {
                    found(&updates.skills)
                        || entry
                            .tracked()
                            .is_some_and(|repo| updates.repos.contains(repo))
                }
            }
        });
        let state = if entry.disabled {
            State::Off
        } else if has_update {
            State::Update
        } else if !waiting.is_empty() {
            State::Waiting
        } else if parts.drift.is_none() {
            State::Unknown
        } else {
            State::InSync
        };
        // Only a plain path is handed to skillshare, which reads this argument as a pattern.
        let plain = plain_path(&entry.path);
        let mut actions = Vec::new();
        if plain {
            actions.push(if entry.disabled { "enable" } else { "disable" });
            if state == State::Update {
                actions.push("update");
            }
            // A skill inside a tracked checkout is not removed on its own.
            if entry.tracked().is_none() {
                actions.push("uninstall");
            }
        }
        if state == State::Waiting {
            actions.push("diff");
        }
        let updates_as = match entry.tracked() {
            Some(repo) if plain_path(repo) => Some(repo.to_owned()),
            Some(_) => None,
            None => plain.then(|| entry.bare().to_owned()),
        };
        items.push(Item {
            id: entry.id(),
            kind,
            name: entry.name.clone(),
            title: entry
                .bare()
                .rsplit('/')
                .next()
                .unwrap_or(&entry.name)
                .to_owned(),
            path: Some(entry.path.clone()),
            description: None,
            state,
            enabled: !entry.disabled,
            origin: Some(match (&entry.repo, &entry.installed_as) {
                (Some(_), _) => "tracked".to_owned(),
                (None, Some(kind)) => kind.clone(),
                (None, None) => "local".to_owned(),
            }),
            source: entry
                .repo
                .clone()
                .or_else(|| entry.source.as_deref().map(safe_url)),
            version: updates.and_then(|updates| {
                updates
                    .versions
                    .get(entry.bare())
                    .or_else(|| updates.versions.get(&entry.name))
                    .cloned()
            }),
            targets: match kind {
                Kind::Agents => agent_targets.clone(),
                _ => skill_targets.clone(),
            },
            waiting,
            actions,
            updates_as,
        });
    }
    if let Some(mcp) = &parts.mcp {
        let mut servers: BTreeMap<&str, (Vec<String>, Vec<Waiting>)> = BTreeMap::new();
        for change in mcp.changes.iter().filter(|change| !change.name.is_empty()) {
            let server = servers.entry(&change.name).or_default();
            if !change.target.is_empty() && !server.0.contains(&change.target) {
                server.0.push(change.target.clone());
            }
            if change.waits() {
                server.1.push(change.waiting());
            }
        }
        for (name, (targets, waiting)) in servers {
            items.push(Item {
                id: format!("mcp:{name}"),
                kind: Kind::Mcp,
                name: name.to_owned(),
                title: name.to_owned(),
                path: None,
                description: None,
                state: if waiting.is_empty() {
                    State::InSync
                } else {
                    State::Waiting
                },
                enabled: true,
                origin: None,
                source: None,
                version: None,
                targets,
                waiting,
                actions: Vec::new(),
                updates_as: None,
            });
        }
    }
    for plugin in parts.plugins.iter().flatten() {
        let waiting: Vec<Waiting> = plugin
            .bindings
            .iter()
            .filter(|(_, waits, _)| *waits)
            .map(|(target, _, _)| Waiting {
                target: target.clone(),
                action: "pending".into(),
            })
            .collect();
        items.push(Item {
            id: format!("plugins:{}", plugin.name),
            kind: Kind::Plugins,
            name: plugin.name.clone(),
            title: plugin.name.clone(),
            path: None,
            description: None,
            state: if waiting.is_empty() {
                State::InSync
            } else {
                State::Waiting
            },
            enabled: true,
            origin: None,
            source: plugin.source.clone(),
            version: plugin.version.clone(),
            targets: plugin
                .bindings
                .iter()
                .map(|(target, _, _)| target.clone())
                .collect(),
            waiting,
            actions: Vec::new(),
            updates_as: None,
        });
    }
    if let Some(hooks) = &parts.hooks {
        for hook in &hooks.entries {
            let waiting: Vec<Waiting> = hook
                .changes
                .iter()
                .filter(|change| change.waits())
                .map(Change::waiting)
                .collect();
            let mut targets: Vec<String> =
                hook.agents.iter().map(|(agent, _)| agent.clone()).collect();
            for change in &hook.changes {
                if !change.target.is_empty() && !targets.contains(&change.target) {
                    targets.push(change.target.clone());
                }
            }
            let state = if !hooks.planned {
                State::Unknown
            } else if !waiting.is_empty() {
                State::Waiting
            } else if !hook.enabled {
                State::Off
            } else {
                State::InSync
            };
            let mut actions = Vec::new();
            if hook.declared && plain_path(&hook.name) && !hook.name.contains('/') {
                actions.push(if hook.enabled { "disable" } else { "enable" });
                actions.push("uninstall");
            }
            items.push(Item {
                id: format!("hooks:{}", hook.name),
                kind: Kind::Hooks,
                name: hook.name.clone(),
                title: hook.name.clone(),
                path: None,
                description: hook.description.clone(),
                state,
                enabled: hook.enabled,
                origin: None,
                source: None,
                version: None,
                targets,
                waiting,
                actions,
                updates_as: None,
            });
        }
    }
    items
}

/// A Markdown file's front matter as rows, and the text after it.
pub(super) fn front_matter(text: &str) -> (Vec<(String, String)>, &str) {
    let start = text.trim_start_matches('\u{feff}');
    let mut lines = start.split_inclusive('\n');
    let Some(first) = lines.next() else {
        return (Vec::new(), text);
    };
    if first.trim_end() != "---" {
        return (Vec::new(), text);
    }
    let mut rows: Vec<(String, String)> = Vec::new();
    let mut read = first.len();
    for line in lines {
        read += line.len();
        let bare = line.trim_end();
        if matches!(bare, "---" | "...") {
            return (rows, &start[read..]);
        }
        if let Some((key, value)) = bare.split_once(':')
            && !key.is_empty()
            && key
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
            && rows.len() < 40
        {
            let value = value.trim();
            // `|` or `>` says the text is the indented lines that follow.
            let block = value.starts_with(['|', '>']) && value.len() <= 3;
            let value = if block { "" } else { unquoted(value) };
            rows.push((key.to_owned(), value.to_owned()));
        } else if bare.starts_with([' ', '\t'])
            && !bare.trim().is_empty()
            && let Some((_, value)) = rows.last_mut()
        {
            if !value.is_empty() {
                value.push(' ');
            }
            value.push_str(bare.trim().trim_start_matches("- "));
        }
    }
    // No closing line: this is not front matter, or the file was cut inside it.
    (Vec::new(), text)
}

pub(super) fn unquoted(text: &str) -> &str {
    let text = text.trim();
    for mark in ['"', '\''] {
        if text.len() >= 2 && text.starts_with(mark) && text.ends_with(mark) {
            return &text[1..text.len() - 1];
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skillshare::parse;

    fn parts() -> Parts {
        Parts {
            status: parse::status(include_str!("fixtures/status.json")),
            listed: listed(include_str!("fixtures/list.json")),
            drift: drift(include_str!("fixtures/diff.json")),
            mcp: mcp(include_str!("fixtures/mcp.json")),
            plugins: plugins(include_str!("fixtures/plugins.json")),
            hooks: hooks(include_str!("fixtures/hooks.json")),
        }
    }

    fn item<'a>(items: &'a [Item], id: &str) -> &'a Item {
        items
            .iter()
            .find(|item| item.id == id)
            .unwrap_or_else(|| panic!("no item {id}"))
    }

    #[test]
    fn every_part_of_a_real_library_is_read() {
        let parts = parts();
        assert!(parts.status.is_some() && parts.listed.is_some() && parts.drift.is_some());
        assert!(parts.mcp.is_some() && parts.plugins.is_some() && parts.hooks.is_some());
        let status = parts.status.unwrap();
        assert_eq!(
            status.agents_source.as_deref(),
            Some("/home/me/.config/skillshare/agents")
        );
        assert_eq!(status.agent_targets, ["claude"]);
        assert_eq!(
            parts.mcp.unwrap().file.as_deref(),
            Some("/home/me/.config/skillshare/config.yaml")
        );
    }

    #[test]
    fn the_library_is_one_list_of_all_five_kinds() {
        let items = items(&parts(), None);
        let ids: Vec<_> = items.iter().map(|item| item.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "skills:group/nested",
                "skills:alpha",
                "skills:beta",
                "skills:pdf-tools",
                "agents:reviewer.md",
                "mcp:docs",
                "mcp:local",
                "plugins:demo",
                "plugins:kept",
                "hooks:check",
            ]
        );
        let alpha = item(&items, "skills:alpha");
        assert_eq!((alpha.state, alpha.enabled), (State::Waiting, true));
        assert_eq!(alpha.targets, ["claude", "universal"]);
        assert_eq!(
            alpha.waiting,
            [
                Waiting {
                    target: "claude".into(),
                    action: "add".into()
                },
                Waiting {
                    target: "universal".into(),
                    action: "add".into()
                },
            ]
        );
        assert_eq!(alpha.actions, ["disable", "uninstall", "diff"]);
        assert_eq!(alpha.origin.as_deref(), Some("local"));
        let nested = item(&items, "skills:group/nested");
        assert_eq!(
            (nested.name.as_str(), nested.title.as_str()),
            ("group__nested", "nested")
        );
        assert_eq!(nested.state, State::Waiting);
        let beta = item(&items, "skills:beta");
        assert_eq!((beta.state, beta.enabled), (State::Off, false));
        assert_eq!(beta.actions, ["enable", "uninstall"]);
        let pdf = item(&items, "skills:pdf-tools");
        assert_eq!(pdf.origin.as_deref(), Some("git-https-subdir"));
        assert_eq!(
            pdf.source.as_deref(),
            Some("example.com/me/good/skills/pdf-tools")
        );
        let reviewer = item(&items, "agents:reviewer.md");
        assert_eq!(
            (reviewer.title.as_str(), reviewer.path.as_deref()),
            ("reviewer", Some("reviewer.md"))
        );
        assert_eq!(reviewer.targets, ["claude"]);
        assert_eq!(reviewer.state, State::Waiting);
        assert_eq!(reviewer.updates_as.as_deref(), Some("reviewer"));
    }

    #[test]
    fn mcp_servers_plugins_and_hooks_say_what_waits_where() {
        let items = items(&parts(), None);
        let docs = item(&items, "mcp:docs");
        assert_eq!(docs.state, State::Waiting);
        assert_eq!(docs.targets, ["claude"]);
        assert_eq!(
            docs.waiting,
            [Waiting {
                target: "claude".into(),
                action: "add".into()
            }]
        );
        assert!(docs.actions.is_empty());
        let demo = item(&items, "plugins:demo");
        assert_eq!(demo.state, State::Waiting);
        assert_eq!(demo.targets, ["claude", "codex"]);
        assert_eq!(
            demo.waiting,
            [Waiting {
                target: "codex".into(),
                action: "pending".into()
            }]
        );
        assert_eq!(demo.source.as_deref(), Some("github.com/owner/plugin"));
        assert_eq!(demo.version.as_deref(), Some("1.2.0"));
        // Kept in the library and bound to no agent program: nothing waits.
        assert_eq!(item(&items, "plugins:kept").state, State::InSync);
        let check = item(&items, "hooks:check");
        assert_eq!(check.state, State::Waiting);
        assert_eq!(
            check.description.as_deref(),
            Some("Run the check after the agent finishes")
        );
        assert_eq!(check.targets, ["claude"]);
        assert_eq!(check.actions, ["disable", "uninstall"]);
    }

    #[test]
    fn a_part_that_was_not_read_leaves_its_items_out_or_unknown() {
        let mut parts = parts();
        parts.drift = None;
        parts.plugins = None;
        let items = items(&parts, None);
        assert_eq!(item(&items, "skills:alpha").state, State::Unknown);
        assert_eq!(item(&items, "skills:beta").state, State::Off);
        assert!(!items.iter().any(|item| item.kind == Kind::Plugins));
        let mut hooks = hooks(include_str!("fixtures/hooks.json")).unwrap();
        hooks.planned = false;
        hooks.entries[0].changes.clear();
        parts.hooks = Some(hooks);
        assert_eq!(
            item(&super::items(&parts, None), "hooks:check").state,
            State::Unknown
        );
    }

    #[test]
    fn a_check_marks_what_has_an_update() {
        let mut updates = Updates::default();
        checked(include_str!("fixtures/check.json"), &mut updates).unwrap();
        checked_agents(include_str!("fixtures/check-agents.json"), &mut updates).unwrap();
        assert_eq!(updates.count(), 1);
        let items = items(&parts(), Some(&updates));
        let pdf = item(&items, "skills:pdf-tools");
        assert_eq!(pdf.state, State::Update);
        assert_eq!(pdf.version.as_deref(), Some("a3acb42"));
        assert_eq!(pdf.actions, ["disable", "update", "uninstall"]);
        assert_eq!(pdf.updates_as.as_deref(), Some("pdf-tools"));
        assert_eq!(item(&items, "skills:alpha").state, State::Waiting);
        assert!(checked("[]", &mut updates).is_none());
        assert!(checked_agents("{}", &mut updates).is_none());
    }

    #[test]
    fn a_skill_in_a_tracked_checkout_updates_with_it_and_is_not_removed_alone() {
        let parts = Parts {
            listed: listed(
                r#"[{"name":"_team__skills__lint","kind":"skill","relPath":"_team/skills/lint","repoName":"_team"},
                    {"name":"odd","kind":"skill","relPath":"draft-*"}]"#,
            ),
            drift: Some(Drift::default()),
            ..Parts::default()
        };
        let mut updates = Updates::default();
        checked(
            r#"{"tracked_repos":[{"name":"_team","status":"behind","behind":3}],"skills":[]}"#,
            &mut updates,
        )
        .unwrap();
        let items = items(&parts, Some(&updates));
        let lint = item(&items, "skills:_team/skills/lint");
        assert_eq!(lint.state, State::Update);
        assert_eq!(lint.actions, ["disable", "update"]);
        assert_eq!(lint.updates_as.as_deref(), Some("_team"));
        assert_eq!(
            (lint.origin.as_deref(), lint.source.as_deref()),
            (Some("tracked"), Some("_team"))
        );
        // A folder name skillshare would read as a pattern is never handed to it.
        let odd = item(&items, "skills:draft-*");
        assert!(odd.actions.is_empty());
        assert_eq!(odd.updates_as, None);
    }

    #[test]
    fn a_hook_conflict_says_why_a_sync_would_be_refused() {
        let hooks = hooks(
            r#"{"source":{"entries":{"lint":{"enabled":false,"bindings":{"codex":{"events":{"Stop":[]}}}}}},
                "plan":{"blocked":true,"changes":[
                  {"target":"codex","name":"lint","action":"conflict","message":"codex already has a Stop hook"},
                  {"target":"claude","name":"gone","action":"remove"},
                  {"action":"conflict","root":"/srv/shop","name":"other"}]}}"#,
        )
        .unwrap();
        assert_eq!(
            hooks.blocked.as_deref(),
            Some(
                "A hook conflicts with one an agent program already has: codex already has a Stop hook"
            )
        );
        let names: Vec<_> = hooks
            .entries
            .iter()
            .map(|hook| (hook.name.as_str(), hook.declared, hook.enabled))
            .collect();
        assert_eq!(names, [("lint", true, false), ("gone", false, true)]);
        let items = items(
            &Parts {
                hooks: Some(hooks),
                ..Parts::default()
            },
            None,
        );
        assert_eq!(item(&items, "hooks:lint").actions, ["enable", "uninstall"]);
        assert!(item(&items, "hooks:gone").actions.is_empty());
        assert_eq!(item(&items, "hooks:gone").state, State::Waiting);
        assert!(super::hooks("[]").is_none());
        assert!(super::hooks("✗ unknown command").is_none());
    }

    #[test]
    fn an_id_names_a_kind_and_a_name() {
        assert_eq!(
            Kind::of("skills:group/nested"),
            Some((Kind::Skills, "group/nested"))
        );
        assert_eq!(Kind::of("mcp:docs"), Some((Kind::Mcp, "docs")));
        assert_eq!(Kind::of("hooks:a:b"), Some((Kind::Hooks, "a:b")));
        for id in ["", "skills", "skills:", "skill:x", ":x", "SKILLS:x"] {
            assert_eq!(Kind::of(id), None, "{id}");
        }
    }

    #[test]
    fn an_address_is_shown_without_scheme_or_sign_in() {
        for (address, shown) in [
            ("https://github.com/owner/repo.git", "github.com/owner/repo"),
            (
                "https://user:token@github.com/owner/repo.git?x=1#frag",
                "github.com/owner/repo",
            ),
            (
                "github.com/owner/repo/skills/pdf",
                "github.com/owner/repo/skills/pdf",
            ),
            (
                "https://example.com/me/good.git//skills/pdf-tools",
                "example.com/me/good/skills/pdf-tools",
            ),
            ("git@github.com:owner/repo.git", "git@github.com:owner/repo"),
            (
                "ssh://git:secret@host.example/owner/repo",
                "ssh://host.example/owner/repo",
            ),
            ("file:///srv/skills.git", "file:///srv/skills"),
        ] {
            assert_eq!(safe_url(address), shown, "{address}");
        }
    }

    #[test]
    fn a_failed_command_gives_its_own_sentence() {
        assert_eq!(
            error(include_str!("fixtures/install-blocked.json")).as_deref(),
            Some("blocked by security audit (use --force to override)")
        );
        for text in ["", "[]", "{}", "{\"error\":\"\"}", "{\"error\":3}", "✗ no"] {
            assert_eq!(error(text), None, "{text}");
        }
    }

    #[test]
    fn front_matter_becomes_rows_and_the_rest_stays_text() {
        let (rows, body) = front_matter(
            "---\nname: alpha\ndescription: \"Use: when testing.\"\nallowed-tools:\n  - Read\n  - Bash\nnote: >-\n  folded\n  text\n---\n\n# Alpha\n",
        );
        assert_eq!(
            rows,
            [
                ("name".to_owned(), "alpha".to_owned()),
                ("description".to_owned(), "Use: when testing.".to_owned()),
                ("allowed-tools".to_owned(), "Read Bash".to_owned()),
                ("note".to_owned(), "folded text".to_owned()),
            ]
        );
        assert_eq!(body, "\n# Alpha\n");
        for text in [
            "# Plain\n",
            "",
            "---\nname: cut off",
            "--- not front matter\n",
        ] {
            let (rows, body) = front_matter(text);
            assert!(rows.is_empty(), "{text}");
            assert_eq!(body, text);
        }
        let (rows, body) = front_matter("\u{feff}---\r\nname: win\r\n---\r\nBody\r\n");
        assert_eq!(rows, [("name".to_owned(), "win".to_owned())]);
        assert_eq!(body, "Body\r\n");
    }
}
