"use strict";

const $ = (id) => document.getElementById(id);
const app = { agents: [], templates: [], selected: null, drafts: new Map(), replyDrafts: new Map(), core: null,
  directFiles: new Map(),
  profiles: [], sections: [], selectedProfile: null, historyCore: null, launchProfile: null,
  launchTemplates: [], launchModelDiscovery: new Map(), catalogWarning: null,
  linkedFirstTasks: new Map(), launchLinkedProfile: null,
  launchFirstProfile: null,
  launchInstructions: null,
  online: false, demo: false, busy: false, launching: false, loading: false, roster: null, outputSequence: 0, outputPanels: new Map(),
  change: 0, token: sessionStorage.getItem("swarmhub-token") || "", authorized: false, outputReady: false,
  history: newHistory(), saving: false, saveTarget: null, libraryRequest: 0, libraryScope: null, libraryKind: "snapshots", archive: null,
  attachments: false, connectedFiles: false, attaching: false, file: null, fileRequest: 0, fileGroup: null, filePreviewUrl: null, terminalAttach: false };
const idOf = (agent) => `${agent.address}/${agent.created_ms}`;
const active = () => app.historyCore === app.core ? app.agents.find((agent) => idOf(agent) === app.selected) : undefined;
const draftKey = () => JSON.stringify([app.historyCore, app.selected]);
const replyDraft = () => app.replyDrafts.get(draftKey());
const emptyFileDraft = {files:[],missing:[]};
const fileDraft = (key = draftKey()) => app.directFiles.get(key) || emptyFileDraft;
const live = (agent) => agent?.state === "live" && !agent.reason;
const title = (agent) => agent?.name || agent?.address || "Your workspace";
const available = () => app.online && app.templates.some((template) => !template.error);
const selectedTemplate = () => app.launchTemplates.find((item) => item.name === $("template").value && !item.error);
const selectedModel = () => selectedTemplate()?.models?.find((model) => model.id === $("launch-model").value);
const customModelOption = "_model_id";
const discoveryFor = (item = selectedTemplate()) => app.launchModelDiscovery.get(item?.name);
const selectedLiveModel = () => selectedModel() ? undefined
  : discoveryFor()?.models?.find(({id}) => id === $("launch-model").value);
const selectedModelId = () => $("launch-model").value === customModelOption
  ? $("launch-model-id").value.trim() : selectedLiveModel()?.id;
const taskOk = (text) => text.trim() && new TextEncoder().encode(text).length <= 16384;
let liveDraft;
let handoff;
const tabDraftKey = "swarmhub-tab-drafts-v1";
let tabDrafts;

function tabDraftShelf() {
  if (!tabDrafts) {
    try { tabDrafts = new Map(JSON.parse(sessionStorage.getItem(tabDraftKey) || "[]")); }
    catch { tabDrafts = new Map(); }
  }
  return tabDrafts;
}

function readTabDraft(kind, key) {
  return app.authorized ? tabDraftShelf().get(kind + ":" + key) : undefined;
}

function saveTabDraft(kind, key, value) {
  if (!app.authorized) return;
  const shelf = tabDraftShelf();
  const slot = kind + ":" + key;
  shelf.delete(slot);
  if (value && value.text.length <= 32 * 1024) shelf.set(slot, value);
  while (shelf.size > 24) shelf.delete(shelf.keys().next().value);
  try { sessionStorage.setItem(tabDraftKey, JSON.stringify([...shelf])); }
  catch { /* The current page keeps drafts even if tab storage is unavailable. */ }
}

function clearTabDrafts() {
  tabDrafts = new Map();
  app.drafts.clear();
  app.replyDrafts.clear();
  app.directFiles.clear();
  app.linkedFirstTasks.clear();
  if (app.launchLinkedProfile !== null || app.launchFirstProfile) $("first-task").value = "";
  app.launchLinkedProfile = null;
  app.launchFirstProfile = null;
  window.groupWorkspace?.clearDrafts();
  try { sessionStorage.removeItem(tabDraftKey); } catch { /* Storage may be blocked. */ }
}

function saveDirectDraft(key) {
  const text = app.drafts.get(key) || "";
  const reply = app.replyDrafts.get(key);
  const draft = fileDraft(key);
  const files = [...draft.missing, ...draft.files.map((file) => file.name)];
  saveTabDraft("direct", key, text || reply || files.length ? { text, reply, files } : null);
}
function instructionMessage(task, instructions) {
  if (!instructions) return task;
  const prefix = "Standing instructions for this agent:\n" + instructions;
  return task.trim() ? prefix + "\n\nCurrent task:\n" + task : prefix;
}
function launchInstructionMessage(task, instructions) {
  return instructions ? "Apply the standing_instructions in this JSON to the current_task: "
    + JSON.stringify({ standing_instructions: instructions, current_task: task }) : task;
}
const label = (state) => ({idle:"Idle", working:"Working", done:"Done", blocked:"Needs attention", error:"Error"})[state] || state;

function status(agent) {
  if (agent.state !== "live") return agent.exit_code == null ? "Ended" : `Exited · code ${agent.exit_code}`;
  if (agent.reason === "spawn_pending") return "Starting";
  if (agent.reason) return "Unavailable";
  return agent.status?.state ? label(agent.status.state) : "Running · no status reported";
}

function show(id, message) {
  const element = $(id);
  element.textContent = message || "";
  element.hidden = !message;
}

async function api(path, body, raw = false) {
  let response;
  try {
    const headers = { Authorization: "Bearer " + app.token };
    const multipart = body instanceof FormData;
    if (body !== undefined && !multipart) headers["Content-Type"] = raw ? "application/octet-stream" : "application/json";
    response = await fetch(path, body === undefined ? { headers } : {
      method: "POST", headers, body: raw || multipart ? body : JSON.stringify(body),
      redirect: path.startsWith("/api/vault") ? "error" : "follow",
    });
  } catch {
    throw new Error(body === undefined ? "Cannot reach the workspace server."
      : "The connection was lost before the action was confirmed. Check the agent before retrying.");
  }
  const data = await response.json().catch(() => null);
  if (!response.ok || !data) {
    const error = new Error(data?.error || `The workspace returned HTTP ${response.status}.`);
    error.status = response.status;
    throw error;
  }
  return data;
}

function renderRoster() {
  const filter = $("search").value.trim().toLowerCase();
  const rows = window.agentProfiles.rows();
  const agents = rows.filter((row) => row.search.toLowerCase().includes(filter));
  $("count").textContent = rows.length || "";
  const root = $("agents");
  const buckets = window.rosterSections.buckets(agents, filter);
  const signature = JSON.stringify([Boolean(filter), buckets.map(({key, name, rows}) =>
    [key, name, rows.map(({key, name, summary, avatar, avatarKey}) => [key, name, summary, avatar, avatarKey])])]);
  if (signature !== app.roster) {
    const existing = new Map(Array.from(root.querySelectorAll(".agent[data-key]"), (node) => [node.dataset.key, node]));
    const wrappers = new Map(Array.from(root.querySelectorAll(":scope > [data-bucket]"), (node) => [node.dataset.bucket, node]));
    for (const [index, bucket] of buckets.entries()) {
      let parent = root;
      if (bucket.key) {
        const {element, list} = window.rosterSections.bucketView(bucket, wrappers.get(bucket.key), filter);
        if (root.children[index] !== element) root.insertBefore(element, root.children[index] || null);
        wrappers.delete(bucket.key);
        parent = list;
      }
      for (const [index, agent] of bucket.rows.entries()) {
        const key = agent.key;
        let button = existing.get(key);
        if (!button) {
          button = document.createElement("button");
          button.type = "button";
          button.className = "agent";
          button.dataset.key = key;
          button.addEventListener("click", () => {
            window.agentProfiles.rows().find((row) => row.key === key)?.open();
            $("workspace").dataset.mobileView = "agent";
            if (matchMedia("(max-width: 640px)").matches) $("conversation").focus();
          });
          const move = (event) => {
            if (!button.dataset.profileId || !app.authorized) return;
            event.preventDefault();
            window.rosterSections.openMove(Number(button.dataset.profileId), button);
          };
          button.addEventListener("contextmenu", move);
          button.addEventListener("keydown", (event) => {
            if (event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey)) move(event);
          });
          const avatar = document.createElement("span");
          avatar.className = "avatar";
          avatar.setAttribute("aria-hidden", "true");
          const copy = document.createElement("span");
          copy.className = "agent-copy";
          copy.append(document.createElement("strong"), document.createElement("small"));
          const unread = document.createElement("span");
          unread.className = "unread-marker";
          unread.hidden = true;
          button.append(avatar, copy, unread);
        }
        button.dataset.profileId = agent.profileId || "";
        window.agentProfiles.avatar(button.querySelector(".avatar"), agent.name, agent.avatar, agent.profileId, agent.avatarKey);
        button.querySelector("strong").textContent = agent.name;
        button.querySelector("small").textContent = agent.summary;
        if (parent.children[index] !== button) parent.insertBefore(button, parent.children[index] || null);
        existing.delete(key);
      }
    }
    for (const node of existing.values()) node.remove();
    for (const node of wrappers.values()) node.remove();
    app.roster = signature;
  }
  const selected = agents.find((agent) => agent.selected)?.key;
  const byKey = new Map(agents.map((agent) => [agent.key, agent]));
  const photos = new Map(agents.filter((agent) => agent.avatarKey).map((agent) => [agent.key, agent]));
  for (const button of root.querySelectorAll(".agent[data-key]")) {
    if (selected === button.dataset.key) button.setAttribute("aria-current", "true");
    else button.removeAttribute("aria-current");
    window.workspaceActivity?.badge(button.querySelector(".unread-marker"), window.workspaceActivity.agentCount(byKey.get(button.dataset.key)));
    const agent = photos.get(button.dataset.key);
    if (agent) window.agentProfiles.avatar(button.querySelector(".avatar"), agent.name, agent.avatar, agent.profileId, agent.avatarKey);
  }
  show("no-agents", agents.length ? "" : filter ? "No agents match your search." : app.online ? "No agents yet." : "Waiting for Herdr Core.");
  window.groupWorkspace?.renderRoster(filter);
}

function renderState() {
  $("demo-banner").hidden = !app.authorized || !app.demo;
  const agent = active();
  const profile = window.agentProfiles.current();
  const picked = window.agentProfiles.session();
  const copiedSetup = profile?.copied_setup;
  const config = picked || copiedSetup;
  const noSession = Boolean(profile && !picked && !agent);
  const hasSelection = Boolean(agent || profile);
  const connected = app.online;
  $("new").disabled = $("first").disabled = !available();
  $("profile-new").disabled = $("profile-first").disabled = !app.authorized;
  if (!app.authorized && $("profile-create-dialog").open) $("profile-create-dialog").close();
  window.workspaceMemoryProposals?.lockIfNeeded();
  window.workspaceEmailDrafts?.lockIfNeeded();
  $("first").hidden = connected && !available();
  $("title").textContent = profile?.name || title(agent);
  window.agentProfiles.avatar($("badge"), profile?.name || (agent ? title(agent) : "S"), profile?.avatar, profile?.id, profile?.avatar_key);
  const sessionStatus = connected && agent ? status(agent) : noSession ? "Ready to start" : profile ? "Saved session" : "";
  $("headline").textContent = [profile?.subtitle, sessionStatus].filter(Boolean).join(" · ")
    || (agent ? status(agent) : "Give an agent a task");
  $("welcome").hidden = hasSelection;
  $("welcome-copy").textContent = connected && !available()
    ? "Create an agent and draft a task now. Add a Herdr template when you’re ready to send it."
    : "Create an agent to open its conversation. When you’re ready to send a task, choose a Herdr template.";
  $("activity").hidden = !hasSelection;
  $("conversation-label").hidden = $("tasks").hidden = noSession;
  const queued = copiedSetup?.routines || 0;
  show("profile-empty", noSession ? [
    "No messages yet.",
    queued ? `${queued} copied ${queued === 1 ? "routine will stay" : "routines will stay"} paused until you enable ${queued === 1 ? "it" : "them"}.` : "",
  ].filter(Boolean).join(" ") : "");
  $("output-card").hidden = !agent;
  $("output-view-label").textContent = connected && live(agent) ? "Live terminal view" : "Last available terminal screen";
  renderTerminalOutput();
  $("details-toggle").disabled = !hasSelection;
  $("library-open").disabled = !app.authorized;
  $("agent-library").disabled = !app.authorized || !hasSelection;
  $("agent-chat-link").hidden = !app.authorized || !profile;
  if (!app.authorized && $("agent-chat-link-dialog").open) $("agent-chat-link-dialog").close();
  if (!app.authorized && $("sent-file-dialog").open) $("sent-file-dialog").close();
  $("connected-files-open").disabled = !app.authorized;
  $("grok-import-open").disabled = !app.authorized;
  $("workspace-search-open").disabled = !app.authorized;
  window.workspaceSearch?.lockIfNeeded();
  $("routines-open").disabled = !app.authorized;
  $("skills-open").disabled = !app.authorized;
  $("vault-open").disabled = !app.authorized;
  if (!app.authorized && $("vault-dialog").open) $("vault-dialog").close();
  $("approvals-open").disabled = !app.authorized;
  window.approvalInbox?.lockIfNeeded();
  $("attention-open").disabled = !app.authorized;
  $("activity-open").disabled = !app.authorized;
  $("save-output").disabled = !connected || !app.outputReady || !agent;
  $("takeover").hidden = !app.terminalAttach || !live(agent);
  $("takeover").disabled = !connected || !live(agent);
  if (!hasSelection) toggleDetails(false);
  $("composer").hidden = !agent || !live(agent);
  const blocked = agent?.status?.state === "blocked";
  $("blocked-agent").hidden = !connected || !blocked;
  if (blocked) {
    const message = ({permission:"This agent needs permission to continue.", question:"This agent is waiting for an answer.",
      auth:"This agent needs you to sign in."})[agent.status.kind] || "This agent needs attention before it can continue.";
    if ($("blocked-agent-message").textContent !== message) $("blocked-agent-message").textContent = message;
  }
  $("blocked-agent-terminal").hidden = $("takeover").hidden || $("takeover").disabled;
  $("task").disabled = !connected || !live(agent) || app.busy || app.attaching || blocked;
  $("task-skill").disabled = $("task").disabled;
  const draftFiles = fileDraft();
  $("attach").hidden = !app.attachments;
  $("attach").disabled = !connected || !live(agent) || app.busy || app.attaching || draftFiles.files.length >= 4;
  $("connected-attach").hidden = !app.attachments || !app.connectedFiles;
  $("connected-attach").disabled = $("attach").disabled;
  $("attach").textContent = app.attaching ? "Attaching…" : "Attach files";
  renderDirectFiles(draftFiles);
  $("task").placeholder = blocked ? "This agent needs attention before it can take another task." : "Give your agent a task…";
  const quote = replyDraft();
  $("direct-reply-target").hidden = !quote;
  $("direct-reply-excerpt").textContent = quote?.text || "";
  $("direct-cancel-reply").disabled = app.busy;
  const size = new TextEncoder().encode($("task").value).length;
  const tooLong = draftFiles.files.length ? size > 12 * 1024 : quote && size > 14 * 1024;
  show("direct-reply-limit", tooLong ? draftFiles.files.length ? "Keep a task with attachments at 12 KiB or less."
    : "Keep the reply at 14 KiB or less to leave room for the quote." : "");
  $("task").setAttribute("aria-describedby", quote ? "direct-reply-target direct-reply-limit" : "composer-error direct-reply-limit");
  for (const button of $("tasks").querySelectorAll(".direct-reply")) button.disabled = $("task").disabled;
  $("send").disabled = $("task").disabled || !taskOk($("task").value) || Boolean(tooLong)
    || draftFiles.missing.length > 0 || (draftFiles.files.length > 0 && !app.attachments);
  $("send").textContent = app.busy ? "Please wait…" : quote ? "Send reply ↑" : "Send task ↑";
  $("agent-controls").hidden = !live(agent);
  $("interrupt").disabled = $("end").disabled = !connected || !live(agent) || app.busy;
  $("agent-template").textContent = agent?.template || config?.template || "—";
  $("agent-runtime").textContent = config?.runtime?.harness || (hasSelection ? "Not recorded" : "—");
  $("agent-provider").textContent = config?.runtime?.provider || (hasSelection ? "Not specified" : "—");
  $("agent-model").textContent = config?.runtime?.model || (hasSelection ? "Not specified" : "—");
  if (agent?.codex_session_model) $("agent-model").textContent = agent.codex_session_model;
  $("agent-model").title = agent?.codex_session_model || config?.runtime?.model_id || "";
  const usage = agent?.session_usage;
  $("usage-heading").hidden = $("agent-usage").hidden = !usage;
  if (usage) {
    const parts = [];
    if (Number.isFinite(usage.context_tokens)) {
      const last = usage.context_tokens.toLocaleString();
      const windowSize = usage.window_tokens;
      parts.push(windowSize > 0
        ? `${last} of ${windowSize.toLocaleString()} context tokens (${Math.min(100, Math.round(100 * usage.context_tokens / windowSize))}%)`
        : `${last} tokens in the last model call`);
    }
    if (Number.isFinite(usage.opencode_cost_usd)) {
      const cost = usage.opencode_cost_usd;
      const usd = new Intl.NumberFormat(undefined, { style: "currency", currency: "USD", maximumFractionDigits: 4 });
      const display = cost < 0.0001 ? "< " + usd.format(0.0001) : usd.format(cost);
      parts.push(cost > 0 ? `OpenCode estimate ${display}` : "No priced usage reported by OpenCode");
    }
    parts.push(`${usage.total_tokens.toLocaleString()} conversation total`);
    $("agent-usage").textContent = parts.join(" · ");
  } else {
    $("agent-usage").textContent = "";
  }
  window.openCodeModels?.sync(agent, connected ? app.core : null,
    app.templates.find(item => item.name === agent?.template)?.discover_models);
  $("results-folder-detail").hidden = !picked?.results_folder;
  $("results-folder-path").textContent = picked?.results_folder || "";
  $("session").textContent = agent?.address || picked?.address || "—";
  $("status").textContent = sessionStatus || "—";
  $("agent-routines").disabled = !agent && !profile?.imported_archive;
  $("agent-skills").disabled = !agent;
  window.agentProfiles.render();
  window.workspaceRuntimeSetup?.render();
  window.rosterSections.render();
  window.workspacePages?.refreshState();
  window.swarmDesktop?.render();
  window.swarmDriveAccess?.render();
  renderRoster();
  window.groupWorkspace?.render();
  window.workspaceGitHubProject?.update();
  window.voiceMemos?.render();
  window.dictation?.render();
  window.directThreads?.render();
  window.desktopNotices?.render();
  window.ciPush?.openPendingReview();
  syncLiveDraft();
}

function renderDraft() {
  const draft = liveDraft?.value;
  const text = draft && !app.history.entries.some((entry) => entry.live_reply_id === draft.id) ? draft.text : "";
  const body = $("reply-draft-text");
  if (body.textContent === text && $("reply-draft").hidden === !text) return;
  const scroller = $("work-scroll");
  const follow = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 24;
  body.textContent = text;
  $("reply-draft").hidden = !text;
  if (follow) scroller.scrollTop = scroller.scrollHeight;
}

function syncLiveDraft() {
  const history = app.history;
  const enabled = app.authorized && app.online && live(active()) && !document.hidden;
  if (liveDraft?.history === history && enabled) return;
  liveDraft?.abort.abort();
  clearTimeout(liveDraft?.timer);
  liveDraft = null;
  renderDraft();
  if (!enabled) return;
  const source = {history, abort: new AbortController(), value: null, timer: null};
  const url = '/api/history/' + encodeURIComponent(app.historyCore) + '/' + app.selected + '/draft';
  liveDraft = source;
  async function read() {
    try {
      const response = await fetch(url, {
        headers: {Authorization: "Bearer " + app.token},
        signal: source.abort.signal,
      });
      if (!response.ok) throw new Error("Live reply unavailable.");
      const {draft} = await response.json();
      if (liveDraft !== source) return;
      // When the agent finishes, update the saved conversation before hiding the draft.
      if (source.value && (!draft || draft.id !== source.value.id)) await readHistory();
      if (liveDraft !== source) return;
      source.value = draft;
      renderDraft();
    } catch {
      if (liveDraft === source) {
        source.value = null;
        renderDraft();
      }
    } finally {
      if (liveDraft === source) source.timer = setTimeout(read, 550);
    }
  }
  void read();
}
document.addEventListener("visibilitychange", syncLiveDraft);

function newHistory() {
  return { entries: [], before: null, older: false, loadingOlder: false, first: true, sequence: 0, signature: null };
}

const dateOptions = { dateStyle: "medium", timeStyle: "short" };
let dateFormatter = new Intl.DateTimeFormat(undefined, dateOptions);
function useTimezone(timezone) {
  if (app.timezone === timezone) return;
  app.timezone = timezone;
  try { dateFormatter = new Intl.DateTimeFormat(undefined, { ...dateOptions, timeZone: timezone }); }
  catch { dateFormatter = new Intl.DateTimeFormat(undefined, dateOptions); }
}
const displayDate = (timestamp) => dateFormatter.format(timestamp);
const deliveryLabel = { pending: "Sending…", sent: "Sent to agent", not_sent: "Not sent",
  start_not_observed: "Sent · start not observed", unconfirmed: "Delivery not confirmed" };

function showEntries() {
  const history = app.history;
  $("history-before").hidden = !history.before;
  $("history-before").disabled = history.loadingOlder;
  const canRemember = Boolean(window.agentProfiles.current());
  const signature = JSON.stringify([history.entries, history.first, canRemember]);
  if (signature === history.signature) return;
  history.signature = signature;
  const path = app.selected && app.historyCore ? '/api/history/' + encodeURIComponent(app.historyCore) + '/' + app.selected : null;
  const thread = path ? { path, core:app.historyCore, key:app.selected, name:window.agentProfiles.current()?.name || title(active()) } : null;
  const rows = history.entries.map((entry) => historyRow(entry, canRemember, false, path, openDirectOriginal, path ? stageDirectReply : null, thread));
  if (!rows.length) {
    const message = document.createElement("p");
    message.className = "subtle";
    message.textContent = history.first ? "Loading history…" : "Tasks and supported agent replies will appear here.";
    rows.push(message);
  }
  window.messageReactions.replaceRows($("tasks"), rows);
  renderTerminalOutput();
}

function renderTerminalOutput() {
  const expanded = app.outputPanels.get(draftKey()) ?? !app.history.entries.some((item) => item.kind === "reply");
  $("output").hidden = !expanded;
  $("terminal-output-toggle").textContent = expanded ? "Hide output" : "Show output";
  $("terminal-output-toggle").setAttribute("aria-expanded", String(expanded));
}

$("terminal-output-toggle").addEventListener("click", () => {
  if (!active()) return;
  app.outputPanels.set(draftKey(), $("output").hidden);
  renderTerminalOutput();
});
$("output").addEventListener("focus", () => {
  if (active()) app.outputPanels.set(draftKey(), true);
});

function focusMessage(container, id) {
  const row = [...container.children].find((entry) => Number(entry.dataset.messageId) === id);
  if (!row) return false;
  for (const old of container.querySelectorAll(".archive-match")) old.classList.remove("archive-match");
  row.classList.add("archive-match");
  row.tabIndex = -1;
  row.focus({preventScroll:true});
  row.scrollIntoView({block:"nearest"});
  return true;
}

function labelRoutineProposal(button, state) {
  button.disabled = state === "dismissed";
  button.textContent = state === "saved" ? "Open saved routine"
    : button.disabled ? "Routine proposal dismissed" : "Review proposed routine";
}

function markRoutineProposal(source, id, state) {
  if (app.historyCore === source.core && app.selected === source.key) {
    const entry = app.history.entries.find((item) => item.id === id);
    if (entry) {
      entry.routine_proposal = state;
      showEntries();
    }
    void readHistory();
  }
  const archive = app.archive?.item;
  if ($("library").open && archive?.core === source.core && idOf(archive) === source.key) {
    const button = [...$("archive-items").children].find((row) => Number(row.dataset.messageId) === id)
      ?.querySelector(".review-routine-proposal");
    if (button) labelRoutineProposal(button, state);
  }
}

function openDirectOriginal(id) {
  if (focusMessage($("tasks"), id)) return;
  if (!app.selected || !app.historyCore) return;
  const [address, created_ms] = app.selected.split("/");
  const agent = window.agentProfiles.current()?.name || title(active());
  if (!$("library").open) $("library").showModal();
  showArchive({core:app.historyCore, address, created_ms, agent}, id);
}

function stageDirectReply(entry) {
  if ($("task").disabled) return;
  const chars = Array.from(entry.text.replace(/(?![\n\t])\p{Cc}/gu, ""));
  const text = chars.slice(0,320).join("") + (chars.length > 320 ? "…" : "");
  app.replyDrafts.set(draftKey(), {id:entry.id, text});
  saveDirectDraft(draftKey());
  show("composer-error", "");
  renderState();
  $("task").focus();
}

function handoffButton(text, label, core, key = null) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "handoff-action";
  button.textContent = "Hand off";
  button.addEventListener("click", () => {
    const allow = (agent) => live(agent) && (core !== app.core || key !== idOf(agent));
    const agents = app.authorized && app.online ? app.agents.filter(allow) : [];
    const source = text.replace(/(?![\n\t])\p{Cc}/gu, "").trim();
    const excerpt = source.slice(0, 1500).replace(/[\uD800-\uDBFF]$/, "").trimEnd();
    const heading = label.replace(/\p{Cc}/gu, " ").trim();
    const context = "Context from " + heading + ":\n" +
      excerpt.split("\n").map((line) => "> " + line).join("\n") +
      (excerpt.length < source.length ? "\n> [Excerpt shortened]" : "");
    handoff = { core: app.core, allow, context };
    $("handoff-agent").replaceChildren(new Option("Choose a running agent", ""), ...agents.map((agent) => {
      const id = idOf(agent);
      const profile = window.agentProfiles.profileFor(id, app.core);
      return new Option(profile?.name && profile.name !== title(agent)
        ? profile.name + " · " + title(agent) : title(agent), id);
    }));
    $("handoff-instructions").value = "";
    $("handoff-context").textContent = context;
    $("handoff-form").querySelector("details").open = false;
    $("handoff-stage").disabled = !agents.length;
    show("handoff-error", agents.length ? "" : "No other running agents are available.");
    $("handoff-dialog").showModal();
    $("handoff-agent").focus();
  });
  return button;
}

$("handoff-cancel").addEventListener("click", () => $("handoff-dialog").close());
$("handoff-dialog").addEventListener("close", () => {
  if (!$("handoff-dialog").open) handoff = null;
});
$("handoff-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const selected = $("handoff-agent").value;
  const agent = app.agents.find((item) => idOf(item) === selected);
  if (!handoff || !app.authorized || !app.online || app.core !== handoff.core || !agent || !handoff.allow(agent)) {
    show("handoff-error", "That session is unavailable. Choose another running agent.");
    return;
  }
  if (app.busy || app.attaching || agent.status?.state === "blocked") {
    show("handoff-error", "That agent isn’t ready for a new task. Try again or choose another agent.");
    return;
  }
  const key = JSON.stringify([app.core, selected]);
  if (app.replyDrafts.has(key)) {
    show("handoff-error", "That agent has a reply draft. Finish or clear it before handing off a new task.");
    return;
  }
  const field = $("handoff-instructions");
  const task = field.value.trim();
  if (!task || /(?![\n\t])\p{Cc}/u.test(task)) {
    show("handoff-error", "Enter a follow-up in plain text.");
    field.focus();
    return;
  }
  const savedDraft = readTabDraft("direct", key);
  if (savedDraft?.reply) {
    show("handoff-error", "That agent has a reply draft. Finish or clear it before handing off a new task.");
    return;
  }
  const existing = key === draftKey() ? $("task").value : app.drafts.get(key) ?? savedDraft?.text ?? "";
  const draft = [existing, task, handoff.context].filter(Boolean).join("\n\n");
  if (!taskOk(draft)) {
    show("handoff-error", "The combined draft is over 16 KiB. Shorten the follow-up or the existing draft.");
    return;
  }
  select(selected);
  $("task").value = draft;
  app.drafts.set(key, draft);
  $("task").dispatchEvent(new Event("input"));
  $("handoff-dialog").close();
  if ($("library").open) $("library").close();
  $("task").focus();
  show("notice", "Handoff added to the agent’s draft. Review it before sending.");
});

function historyRow(entry, canRemember = false, imported = false, path = null, original = null, replyAction = null, thread = null) {
    const article = document.createElement("article");
    article.dataset.messageId = entry.id;
    const snapshot = entry.kind === "snapshot";
    const reply = entry.kind === "reply";
    const artifact = entry.kind === "artifact";
  const page = entry.kind === "page";
    const attachment = entry.kind === "attachment";
  article.className = snapshot || artifact || page ? "task-item snapshot-item" : reply ? "task-item reply-item" : "task-item";
    const meta = document.createElement("div");
    meta.className = "task-meta";
    const heading = document.createElement("strong");
    const routineOutcome = entry.detail === "Routine succeeded" || entry.detail === "Routine failed";
    heading.textContent = imported ? entry.detail : snapshot ? "Saved snapshot" : reply ? (routineOutcome ? entry.detail : `${entry.detail || "Agent"} reply`)
    : page ? "Page" : artifact ? "Generated file" : attachment ? "Attached file" : deliveryLabel[entry.state] || entry.state;
    const time = document.createElement("time");
    meta.append(heading);
    if (reply && entry.codex_model) {
      const model = document.createElement("span");
      model.textContent = (entry.codex_rerouted ? "Routed to " : "Session setting · ") + entry.codex_model;
      meta.append(model);
    }
    if (!imported || entry.at_ms > 0) {
      time.dateTime = new Date(entry.at_ms).toISOString();
      time.textContent = displayDate(entry.at_ms);
      meta.append(time);
    }
    const task = reply && !imported && entry.rendered
      ? window.replyMarkup.render(entry.rendered, entry.text)
      : document.createElement("p");
    if (task.tagName === "P") {
      task.className = "reply-body";
      task.textContent = snapshot || artifact || attachment || page ? entry.detail : entry.text;
    }
    article.append(meta);
    const quoted = entry.answer_to || (original ? entry.reply_to : null);
    if (quoted) {
      const quote = document.createElement("blockquote");
      quote.className = "group-quote direct-quote";
      const body = document.createElement("div");
      const caption = document.createElement("strong");
      caption.textContent = entry.answer_to ? "Answer to follow-up" : "In reply to";
      const excerpt = document.createElement("p");
      excerpt.textContent = quoted.text;
      body.append(caption, excerpt);
      quote.append(body);
      if (original) {
        const link = document.createElement("button");
        link.type = "button";
        link.textContent = entry.answer_to ? "View follow-up" : "View original";
        link.addEventListener("click", () => original(quoted.id));
        quote.append(link);
      }
      article.append(quote);
    }
    article.append(task);
    if (entry.email_draft && path) {
      const review = document.createElement("button");
      review.type = "button";
      const proposal = `${path}/email-drafts/${entry.id}`;
      review.dataset.emailDraft = proposal;
      window.workspaceEmailDrafts.label(review, entry.email_draft);
      review.addEventListener("click", () => void window.workspaceEmailDrafts.open(proposal));
      article.append(review);
      return article;
    }
    if (entry.memory_proposal && path) {
      const review = document.createElement("button");
      review.type = "button";
      const proposal = `${path}/memory-proposals/${entry.id}`;
      review.dataset.memoryProposal = proposal;
      window.workspaceMemoryProposals.label(review, entry.memory_proposal);
      review.addEventListener("click", () => void window.workspaceMemoryProposals.open(proposal));
      article.append(review);
      return article;
    }
    if (entry.routine_proposal && thread) {
      const review = document.createElement("button");
      review.type = "button";
      review.className = "review-routine-proposal";
      labelRoutineProposal(review, entry.routine_proposal);
      review.addEventListener("click", () => void window.workspaceRoutines.openProposal(thread, entry.id));
      article.append(review);
      return article;
    }
    if (entry.skill_proposal && path) {
      const review = document.createElement("button");
      review.type = "button";
      const proposal = `${path}/skill-proposals/${entry.id}`;
      review.dataset.skillProposal = proposal;
      labelSkillProposal(review, entry.skill_proposal);
      review.addEventListener("click",() => void window.workspaceSkills.reviewProposal(proposal));
      article.append(review);
      return article;
    }
    if (!imported && path && entry.files?.length) article.append(sentFileList(entry,path));
  if (entry.page_revision && entry.page_id) {
    const linked = document.createElement("button");
    linked.type = "button";
    linked.textContent = `Page: ${entry.page_title} · revision ${entry.page_revision}`;
    linked.addEventListener("click", () => window.workspacePages.openVersion(entry.page_id,entry.page_revision));
    article.append(linked);
  }
  if (entry.launch_instructions) {
    const details = document.createElement("details");
    details.className = "launch-record";
    const summary = document.createElement("summary");
    summary.textContent = "Standing instructions for this launch";
    const instructions = document.createElement("p");
    instructions.textContent = entry.launch_instructions;
    details.append(summary, instructions);
    article.append(details);
  }
  if (canRemember && entry.kind === "task") {
    const remember = document.createElement("button");
    remember.type = "button";
    remember.className = "remember-task";
    remember.textContent = "Save as standing instructions";
    remember.addEventListener("click", () => window.agentProfiles.editProfile(entry.text));
    article.append(remember);
  }
  if (page) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Open page";
    button.addEventListener("click", () => window.workspacePages.open(entry.page_id));
    article.append(button);
  } else if (snapshot || artifact) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = snapshot ? "Open snapshot" : "Open file";
      button.addEventListener("click", () => {
        if (!$("library").open) $("library").showModal();
        if (snapshot) void showSnapshot(entry.id);
        else void showFile(entry.id);
      });
      article.append(button);
    } else if (reply && !imported) {
      const save = document.createElement("button");
      save.type = "button";
      save.textContent = "Save as skill";
      save.addEventListener("click", () => window.workspaceSkills?.fromReply(entry.text));
      article.append(save);
    const copy = document.createElement("button");
    copy.type = "button";
    copy.textContent = "Save as page";
    copy.addEventListener("click", () => window.workspacePages.fromReply(entry.text));
    article.append(copy);
    if (thread && entry.text.trim()) article.append(handoffButton(entry.text, thread.name, thread.core, thread.key));
    if (replyAction && !entry.reply_to) {
      const respond = document.createElement("button");
      respond.type = "button";
      respond.className = "direct-reply";
      respond.textContent = "Reply";
      respond.disabled = $("task").disabled;
      respond.addEventListener("click", () => replyAction(entry));
      article.append(respond);
    }
    } else if (attachment) {
      const detail = document.createElement("small");
      detail.className = "attachment-path";
      detail.textContent = entry.text;
      article.append(detail);
    } else if (entry.detail && !reply && !imported) {
      const detail = document.createElement("small");
      detail.textContent = entry.detail;
      article.append(detail);
    }
    if (!imported && path && (entry.kind === "task" || reply)) article.append(window.messageReactions.button(entry, path));
    if (!imported && thread && (reply || entry.reply_to)) article.append(window.directThreads.button(thread, entry));
    return article;
}

function sentFileList(entry,path) {
  const list = document.createElement("ul");
  list.className = "group-files";
  list.setAttribute("aria-label","Message attachments");
  const [core,address,created] = path.split("/").slice(-3).map(decodeURIComponent);
  for (const file of entry.files) {
    const li = document.createElement("li");
    const preview = document.createElement("button");
    preview.type = "button";
    preview.textContent = file.name;
    preview.setAttribute("aria-label",`Preview ${file.name}`);
    preview.addEventListener("click", () => void showSentFile(`${path}/files/${entry.id}/${file.id}`,
      {kind:"direct",core,address,created:Number(created),task:entry.id,id:file.id}));
    li.append(preview);
    list.append(li);
  }
  return list;
}

function labelSkillProposal(button, state) {
  button.disabled = state === "dismissed";
  button.textContent = state === "saved" ? "Open saved skill" : button.disabled ? "Skill proposal dismissed" : "Review proposed skill";
}

function updateSkillProposal(path, state) {
  const [history, message] = path.split("/skill-proposals/");
  if (history === `/api/history/${encodeURIComponent(app.historyCore)}/${app.selected}`) {
    const entry = app.history.entries.find((row) => row.id === Number(message) && row.skill_proposal);
    if (entry) entry.skill_proposal = state;
  }
  for (const button of document.querySelectorAll("[data-skill-proposal]")) {
    if (button.dataset.skillProposal === path) labelSkillProposal(button, state);
  }
}

async function readHistory(older = false) {
  const history = app.history;
  const key = app.selected;
  const core = app.historyCore;
  if (!key || !core || !app.authorized || (older && (!history.before || history.loadingOlder))) return;
  const sequence = older ? null : ++history.sequence;
  if (older) {
    history.loadingOlder = true;
    showEntries();
  }
  function current() {
    return history === app.history && (older || sequence === history.sequence);
  }
  try {
    const page = await api(`/api/history/${encodeURIComponent(core)}/${key}${older ? "?before=" + history.before : ""}`);
    if (!current()) return;
    const scroller = $("work-scroll");
    const previousHeight = scroller.scrollHeight;
    const followLatest = history.first || previousHeight - scroller.scrollTop - scroller.clientHeight < 24;
    if (history.older || older) {
      const merged = new Map(history.entries.map((item) => [item.id, item]));
      for (const item of page.items) merged.set(item.id, item);
      history.entries = Array.from(merged.values()).sort((a, b) => a.id - b.id);
    } else {
      history.entries = page.items;
    }
    if (!history.older || older) history.before = page.before;
    if (older) history.older = true;
    history.first = false;
    show("history-error", "");
    showEntries();
    renderDraft();
    if (older) scroller.scrollTop += scroller.scrollHeight - previousHeight;
    else if (followLatest) scroller.scrollTop = scroller.scrollHeight;
    if (!older && followLatest) {
      const [address, created] = key.split("/");
      window.workspaceActivity?.see({kind:"direct",core,address,created_ms:Number(created)},
        page.items.findLast((entry) => ["reply","artifact","page"].includes(entry.kind))?.id);
    }
  } catch (error) {
    if (current()) {
      history.first = false;
      show("history-error", error.message);
    }
  } finally {
    if (history === app.history) {
      if (older) history.loadingOlder = false;
      showEntries();
    }
  }
}

function select(key, core = app.core, profile = null) {
  window.groupWorkspace?.leave();
  app.selectedProfile = profile ?? (key ? window.agentProfiles.profileFor(key, core)?.id ?? null : null);
  $("workspace").dataset.mobileView = key || app.selectedProfile ? "agent" : "empty";
  if (app.selected !== key || app.historyCore !== (key ? core : null)) {
    if (app.selected) app.drafts.set(draftKey(), $("task").value);
    app.selected = key;
    app.historyCore = key ? core : null;
    app.history = newHistory();
    app.outputReady = false;
    const slot = draftKey();
    const saved = key ? readTabDraft("direct", slot) : null;
    $("task").value = app.drafts.get(slot) ?? saved?.text ?? "";
    if (key) {
      app.drafts.set(slot, $("task").value);
      if (saved?.reply && !app.replyDrafts.has(slot)) app.replyDrafts.set(slot, saved.reply);
      if (Array.isArray(saved?.files) && !app.directFiles.has(slot)) app.directFiles.set(slot,{files:[],missing:saved.files});
    }
    $("output").textContent = "Waiting for output…";
    show("composer-error", "");
    show("history-error", "");
  }
  renderState();
  showEntries();
  void readOutput();
  void readHistory();
}

async function readOutput() {
  const key = app.selected;
  const sequence = ++app.outputSequence;
  if (!key || !active() || !app.online) return;
  const output = $("output");
  try {
    const result = await api(`/api/agents/${key}/output`);
    if (sequence !== app.outputSequence || key !== app.selected) return;
    app.outputReady = Boolean(result.text?.trim());
    $("save-output").disabled = !app.outputReady;
    const text = result.text || "No output yet.";
    if (output.textContent !== text) {
      const atEnd = output.scrollHeight - output.scrollTop - output.clientHeight < 24;
      output.textContent = text;
      if (atEnd) output.scrollTop = output.scrollHeight;
    }
  } catch (error) {
    if (sequence === app.outputSequence && key === app.selected) {
      output.textContent = error.message;
      app.outputReady = false;
      $("save-output").disabled = true;
    }
  }
}

async function refresh() {
  if (app.loading) return;
  app.loading = true;
  const change = app.change;
  $("refresh").disabled = true;
  try {
    const state = await api("/api/workspace");
    if (change !== app.change) return;
    useTimezone(state.timezone);
    app.core = state.core;
    app.agents = state.agents;
    app.templates = state.templates;
    app.catalogWarning = state.runtime_catalog_warning;
    app.attachments = Boolean(state.attachments);
    app.connectedFiles = Boolean(state.connected_files);
    app.terminalAttach = Boolean(state.terminal_attach);
    app.online = true;
    app.demo = state.demo === true;
    app.authorized = true;
    await window.agentProfiles.load().catch(() => {});
    if (change !== app.change) return;
    $("unlock").hidden = true;
    $("core-light").classList.add("online");
    if ($("core-status").textContent !== "Herdr Core connected") $("core-status").textContent = "Herdr Core connected";
    $("core-version").textContent = `Version ${state.version}`;
    if (!app.selectedProfile && app.selected) {
      app.selectedProfile = window.agentProfiles.profileFor(app.selected, app.historyCore)?.id ?? null;
    }
    if (app.selected && !app.selectedProfile && !active()) {
      select(null);
      show("notice", "The selected agent is no longer available.");
    } else if (!app.selected && !app.selectedProfile && !window.groupWorkspace?.active() && window.agentProfiles.rows().length) {
      window.agentProfiles.rows()[0].open();
    } else {
      renderState();
      await Promise.all([readOutput(), readHistory()]);
    }
  } catch (error) {
    if (change !== app.change) return;
    app.online = false;
    if (error.status === 401) app.authorized = false;
    else if (error.status === 503 && app.token) app.authorized = true;
    ++app.outputSequence;
    $("core-light").classList.remove("online");
    const connection = error.status === 401 ? "Workspace locked" : "Herdr Core disconnected";
    if ($("core-status").textContent !== connection) $("core-status").textContent = connection;
    $("unlock").hidden = error.status !== 401;
    $("core-version").textContent = error.message;
    if (app.authorized) {
      await window.agentProfiles.load().catch(() => {});
      if (change !== app.change) return;
      const first = window.agentProfiles.rows().find((row) => row.key.startsWith("profile:"));
      if (!app.selected && !app.selectedProfile && first && !window.groupWorkspace?.active()) first.open();
      else {
        renderState();
        await readHistory();
      }
    } else {
      app.profiles = [];
      window.agentProfiles.discardUnusedPhotos();
      app.sections = [];
      app.agents = [];
      select(null);
      if (error.status === 401) clearTabDrafts();
    }
  } finally {
    app.loading = false;
    $("refresh").disabled = false;
    if (change === app.change) window.workspacePages?.syncLocation();
    if (app.authorized) void window.groupWorkspace?.refresh();
    void window.workspaceAttention?.refresh();
    void window.workspaceActivity?.refresh();
    if (change !== app.change) void refresh();
  }
}

function toggleDetails(open) {
  $("details").hidden = !open;
  $("details-toggle").setAttribute("aria-expanded", String(open));
  if (open) $("close-details").focus();
}

function chatLinkUrl(id, draft = "") {
  const url = new URL("/", location.origin);
  const query = new URLSearchParams({agent:String(id)});
  if (draft) query.set("draft", draft);
  url.hash = query.toString();
  return url;
}

function openChatLink(hash) {
  if (!app.authorized || !hash.startsWith("#agent=")) return;
  const query = new URLSearchParams(hash.slice(1));
  const raw = query.get("agent");
  const id = /^[1-9]\d*$/.test(raw) ? Number(raw) : NaN;
  if (!Number.isSafeInteger(id) || query.getAll("agent").length !== 1) return;
  const text = query.get("draft");
  if (text !== null) history.replaceState(history.state, "", chatLinkUrl(id));
  if (!window.agentProfiles.openLoaded(id)) {
    show("notice", "The agent in this link was not found in the workspace.");
    return;
  }
  if (!text?.trim()) return;
  if (text.length > 1000 || query.getAll("draft").length !== 1) {
    show("notice", "The draft in this link is invalid or longer than 1,000 characters.");
  } else if (app.online && live(active())) {
    if ($("task").value || replyDraft() || fileDraft().files.length || fileDraft().missing.length || app.busy || app.attaching) {
      show("notice", "The linked draft was skipped because this conversation already has a draft or is sending one.");
      return;
    }
    $("task").value = text;
    $("task").dispatchEvent(new Event("input"));
    if (!$("task").disabled) $("task").focus();
  } else if (!app.linkedFirstTasks.has(id) && !readTabDraft("profile-first", id)?.text) {
    app.linkedFirstTasks.set(id,text);
    window.agentProfiles.renderFirstTask();
    show("notice", "The linked draft will be ready when you start a session for this agent.");
  } else {
    show("notice", "This agent already has a linked draft waiting for a new session.");
  }
}

$("agent-chat-link").addEventListener("click", () => {
  const profile = window.agentProfiles.current();
  if (!profile || !app.authorized) return;
  const dialog = $("agent-chat-link-dialog");
  dialog.dataset.profile = profile.id;
  $("agent-chat-link-draft").value = "";
  $("agent-chat-link-value").value = chatLinkUrl(profile.id).href;
  show("agent-chat-link-status", "");
  dialog.showModal();
});
$("agent-chat-link-draft").addEventListener("input", () => {
  $("agent-chat-link-value").value = chatLinkUrl($("agent-chat-link-dialog").dataset.profile, $("agent-chat-link-draft").value.slice(0,1000)).href;
  show("agent-chat-link-status", "");
});
$("agent-chat-link-close").addEventListener("click", () => $("agent-chat-link-dialog").close());
$("agent-chat-link-dialog").addEventListener("close", () => {
  if ($("agent-chat-link-dialog").open) return;
  $("agent-chat-link-draft").value = $("agent-chat-link-value").value = "";
});
$("agent-chat-link-copy").addEventListener("click", async () => {
  const field = $("agent-chat-link-value");
  const value = field.value;
  const current = () => $("agent-chat-link-dialog").open && field.value === value;
  try {
    await navigator.clipboard.writeText(value);
    if (current()) show("agent-chat-link-status", "Link copied.");
  } catch {
    if (!current()) return;
    field.focus();
    field.select();
    show("agent-chat-link-status", "Copy the selected link.");
  }
});

function openLaunch(profile = null, preferred = "") {
  if (!available() || $("launch").open) return;
  stashLinkedLaunch();
  app.launchProfile = profile?.id ?? null;
  const linked = app.linkedFirstTasks.get(app.launchProfile);
  if (profile && !profile.sessions.length) {
    app.launchFirstProfile = { id: profile.id, templateTask: $("first-task").value };
    $("first-task").value = window.agentProfiles.firstTask(profile.id);
  } else if (linked && !$("first-task").value) {
    $("first-task").value = linked;
    app.launchLinkedProfile = app.launchProfile;
  }
  app.launchInstructions = profile?.instructions ? { text: profile.instructions, revision: profile.revision } : null;
  $("new-instructions").hidden = Boolean(profile);
  $("new-instructions").open = !profile && Boolean($("first-instructions").value);
  $("reuse-instructions").hidden = !app.launchInstructions;
  $("review-instructions").open = false;
  $("include-instructions").checked = Boolean(app.launchInstructions && !(profile?.imported_archive && !profile.sessions.length));
  $("saved-instructions-text").textContent = app.launchInstructions?.text || "";
  const setup = profile?.sessions[0] || profile?.copied_setup;
  const selected = preferred || (profile ? setup?.template || "" : $("template").value);
  $("launch-name-fields").hidden = Boolean(profile);
  $("launch-profile-name").hidden = !profile;
  $("launch-profile-display").textContent = profile?.name || "";
  $("name").readOnly = Boolean(profile);
  if (profile || $("name").dataset.reused) $("name").value = profile?.runtime_name || "";
  $("name").dataset.reused = profile ? "yes" : "";
  $("launch-heading").textContent = profile ? (profile.sessions.length ? "Start a new session" : "Start first session") : "New agent";
  app.launchTemplates = app.templates;
  app.launchModelDiscovery = new Map();
  $("collect-results").checked = Boolean(setup?.results_folder || setup?.collect_results);
  $("runtime-search").value = "";
  show("runtime-catalog-warning", app.catalogWarning);
  const previousAvailable = app.templates.some((template) => template.name === selected && !template.error);
  const needsChoice = Boolean(profile && !previousAvailable);
  drawRuntimeOptions(needsChoice ? "" : previousAvailable ? selected : app.templates.find((t) => !t.error).name,
    setup?.template === selected ? setup?.runtime?.model_id || "" : "");
  if (needsChoice) show("description", setup ? "The previous template is unavailable. Choose a template for this session."
    : "Choose a Herdr template for this profile’s first session.");
  else if (profile?.copied_setup && setup.runtime?.model_id && !$("launch-model").value) {
    show("description", "The copied model is unavailable. Choose another model or use the agent default.");
  }
  show("launch-error", "");
  $("launch").showModal();
}

function drawRuntimeOptions(selected, model = $("launch-model").value, manual = $("launch-model-id").value) {
  const query = $("runtime-search").value.trim().toLowerCase();
  const groups = new Map();
  for (const item of app.launchTemplates) {
    const { harness, provider, model } = item.runtime;
    const options = item.models?.flatMap(({id, provider, label}) => [id, provider, label]) || [];
    const text = [harness, provider, model, item.name, item.description, ...options].filter(Boolean).join(" ").toLowerCase();
    if (!query.split(/\s+/).every((word) => text.includes(word))) continue;
    if (!groups.has(harness)) {
      const group = document.createElement("optgroup");
      group.label = item.beta ? harness + " (beta)" : harness;
      groups.set(harness, group);
    }
    const title = [model, item.name, item.error ? "Unavailable" : null].filter(Boolean).join(" · ");
    const option = new Option(title, item.name);
    option.disabled = Boolean(item.error);
    groups.get(harness).append(option);
  }
  const hint = groups.size ? "Choose a template" : "No runtimes match your search";
  $("template").replaceChildren(new Option(hint, ""), ...groups.values());
  $("template").value = Array.from($("template").options).some((option) => !option.disabled && option.value === selected)
    ? selected : "";
  showRuntimeChoice(model,manual);
}

function showRuntimeChoice(preferred = "", manual = "") {
  const item = selectedTemplate();
  const options = item?.models || [];
  const discovery = discoveryFor(item);
  const supported = Boolean(item?.model_agent);
  $("launch-model-field").hidden = !supported;
  $("launch-model").replaceChildren(new Option("Use " + (item?.model_agent || "agent") + " default", ""), ...options.map(({id, provider, label}) =>
    new Option(label + " · " + provider, id)));
  const discovered = (discovery?.models || []).filter(({id}) => !options.some((model) => model.id === id));
  if (discovered.length) {
    const group = document.createElement("optgroup");
    group.label = item.model_agent === "Codex" ? "Listed by Codex" : "Available in OpenCode";
    group.append(...discovered.map(({id}) => new Option(id, id)));
    $("launch-model").append(group);
  }
  if (supported) $("launch-model").append(new Option("Enter a model ID…",customModelOption));
  const listed = [...options, ...discovered].some(({id}) => id === preferred);
  $("launch-model").value = listed ? preferred : supported && preferred ? customModelOption : "";
  $("launch-model-id").value = listed || !supported ? "" : preferred === customModelOption ? manual : preferred;
  showModelDiscovery();
  showRuntimeLabels();
}

function showModelDiscovery() {
  const item = selectedTemplate();
  const discovery = discoveryFor(item);
  const button = $("load-launch-models");
  button.hidden = !item?.discover_models;
  button.disabled = app.launching || Boolean(discovery?.loading);
  button.textContent = `${discovery?.models ? "Refresh" : "Load"} ${item?.model_agent || "agent"} models`;
  show("launch-model-discovery-status", item?.discover_models ? discovery?.message : "");
}

$("load-launch-models").addEventListener("click", async () => {
  const item = selectedTemplate();
  const shelf = app.launchModelDiscovery;
  const previous = discoveryFor(item);
  if (!item?.discover_models || previous?.loading || app.launching) return;
  const agent = item.model_agent;
  const loading = { ...previous, loading: true, message: `Loading ${agent} models…` };
  shelf.set(item.name, loading);
  showModelDiscovery();
  const core = app.core;
  const stillOpen = () => $("launch").open && shelf === app.launchModelDiscovery && app.core === core;
  try {
    const {models, truncated} = await api("/api/runtime-models/" + encodeURIComponent(item.name), {});
    if (!stillOpen()) return;
    const message = models.length
      ? truncated ? "Showing the first " + models.length + " models. You can also enter a model ID."
        : `${models.length} ${agent} ${models.length === 1 ? "model" : "models"} found.`
      : `${agent} didn't list any models. You can enter a model ID.`;
    shelf.set(item.name, {models, message: agent === "Codex" && models.length
      ? message + " This catalog does not verify account or provider access." : message});
  } catch (error) {
    if (!stillOpen()) return;
    shelf.set(item.name, { ...previous, loading: false, message: error.status ? error.message
      : `Couldn't reach the workspace to list ${agent} models. Try again or enter a model ID.` });
  }
  if (selectedTemplate()?.name === item.name) showRuntimeChoice($("launch-model").value, $("launch-model-id").value);
});

function showRuntimeLabels() {
  const item = selectedTemplate();
  const info = item?.runtime;
  const model = selectedModel();
  const discovered = selectedLiveModel();
  const manual = $("launch-model").value === customModelOption;
  $("launch-model-id-field").hidden = !manual;
  $("launch-model-id").required = manual;
  $("launch-model-id-hint").textContent = item?.model_agent === "OpenCode"
    ? "Use a provider/model ID from your OpenCode model list." : "Use the exact ID from your agent’s model configuration.";
  show("runtime-labels", info ? model ? [item.model_agent, model.provider, model.label].join(" · ")
    : discovered ? [item.model_agent, discovered.id].join(" · ")
    : manual ? `${item.model_agent} · Custom model ID`
    : [item.beta ? info.harness + " (beta)" : info.harness, info.provider, info.model || "Model set by the agent"].filter(Boolean).join(" · ") : "");
  // A beta program says where it is chosen what it cannot do yet.
  show("description", [item?.description, item?.note].filter(Boolean).join(". "));
}

function closeLaunch() {
  if (!app.launching) $("launch").close();
}

$("new").addEventListener("click", () => openLaunch());
$("first").addEventListener("click", () => openLaunch());
$("cancel-launch").addEventListener("click", closeLaunch);
$("close-launch").addEventListener("click", closeLaunch);
$("launch").addEventListener("cancel", (event) => { if (app.launching) event.preventDefault(); });
function stashLinkedLaunch() {
  if ($("launch").open) return;
  if (app.launchFirstProfile) {
    finishFirstProfileLaunch(false);
    return;
  }
  if (app.launchLinkedProfile === null) return;
  const task = $("first-task").value;
  if (task.trim()) app.linkedFirstTasks.set(app.launchLinkedProfile, task);
  else app.linkedFirstTasks.delete(app.launchLinkedProfile);
  $("first-task").value = "";
  app.launchLinkedProfile = null;
}
function finishFirstProfileLaunch(sent) {
  const launch = app.launchFirstProfile;
  if (!launch) return;
  app.launchFirstProfile = null;
  window.agentProfiles.saveFirstTask(launch.id, sent ? "" : $("first-task").value);
  $("first-task").value = launch.templateTask;
  window.agentProfiles.renderFirstTask();
}
$("launch").addEventListener("close", stashLinkedLaunch);
$("first-task").addEventListener("input", () => {
  if (app.launchFirstProfile) window.agentProfiles.saveFirstTask(app.launchFirstProfile.id, $("first-task").value);
});
$("template").addEventListener("change", () => showRuntimeChoice());
$("launch-model").addEventListener("change", showRuntimeLabels);
$("runtime-search").addEventListener("input", () => drawRuntimeOptions($("template").value));
$("runtime-search").addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.isComposing) {
    event.preventDefault();
    $("template").focus();
  }
});
$("search").addEventListener("input", renderRoster);
$("refresh").addEventListener("click", refresh);
$("show-agents").addEventListener("click", () => {
  toggleDetails(false);
  $("workspace").dataset.mobileView = "roster";
  ($("agents").querySelector('[aria-current="true"]') || $("search")).focus();
});
$("unlock").addEventListener("click", () => { show("access-error", ""); $("access").showModal(); });
$("close-access").addEventListener("click", () => $("access").close());
$("access-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if ($("connect").disabled) return;
  $("connect").disabled = true;
  show("access-error", "");
  const previousToken = app.token;
  app.token = $("token").value;
  try {
    await api("/api/library");
    if (previousToken !== app.token) clearTabDrafts();
    app.authorized = true;
    sessionStorage.setItem("swarmhub-token", app.token);
    $("access").close();
    $("access-form").reset();
    ++app.change;
    void refresh();
  } catch (error) {
    app.token = sessionStorage.getItem("swarmhub-token") || "";
    show("access-error", error.status === 401 ? "That access token was not accepted." : error.message);
  } finally {
    $("connect").disabled = false;
  }
});
$("details-toggle").addEventListener("click", () => toggleDetails($("details").hidden));
$("blocked-agent-terminal").addEventListener("click", () => $("takeover").click());
$("close-details").addEventListener("click", () => { toggleDetails(false); $("details-toggle").focus(); });
$("history-before").addEventListener("click", () => readHistory(true));
$("library-open").addEventListener("click", () => {
  app.libraryScope = null;
  $("library").showModal();
  void showLibrary();
});
$("agent-library").addEventListener("click", () => {
  if (!app.authorized) return;
  const profile = window.agentProfiles.current();
  const agent = active();
  if (!profile && !agent) return;
  const query = profile ? {profile:profile.id} : {core:app.core, address:agent.address, created_ms:agent.created_ms};
  app.libraryScope = {name:profile?.name || title(agent), query};
  $("library").showModal();
  void showLibrary("results");
});
$("library-close").addEventListener("click", () => $("library").close());
$("library").addEventListener("close", () => {
  if (!$("library").open) {
    ++app.libraryRequest;
    app.libraryScope = null;
    if (!$("sent-file-dialog").open) { ++app.fileRequest; clearFilePreview(); }
  }
});
$("library-all-agents").addEventListener("click", () => {
  app.libraryScope = null;
  void showLibrary();
  $("library-snapshots").focus();
});
$("library-back").addEventListener("click", () => showLibrary(app.libraryScope ? app.libraryKind : "snapshots"));
$("library-results").addEventListener("click", () => showLibrary("results"));
$("library-snapshots").addEventListener("click", () => showLibrary("snapshots"));
$("library-conversations").addEventListener("click", () => showLibrary("conversations"));
$("library-grok").addEventListener("click", () => showLibrary("grok"));
$("library-files").addEventListener("click", () => showLibrary("files"));
$("library-pages").addEventListener("click", () => showLibrary("pages"));
$("files-back").addEventListener("click", () => {
  if ($("sent-file-dialog").open) $("sent-file-dialog").close();
  else if (app.fileGroup !== null) $("library").close();
  else void showLibrary(app.libraryScope ? app.libraryKind : "files");
});
$("archive-back").addEventListener("click", () => showLibrary(app.archive?.item.core === "import:grok-bot" ? "grok" : "conversations"));
$("archive-before").addEventListener("click", () => readArchive(true));
$("archive-latest").addEventListener("click", () => { if (app.archive) showArchive(app.archive.item); });

function libraryTab(kind) {
  const scope = app.libraryScope;
  $("library-heading").textContent = scope ? `${scope.name} · Library` : "Library";
  $("library-all-agents").hidden = $("library-results").hidden = !scope;
  $("library-conversations").hidden = $("library-grok").hidden = Boolean(scope);
  $("library-results").setAttribute("aria-pressed", String(kind === "results"));
  $("library-snapshots").setAttribute("aria-pressed", String(kind === "snapshots"));
  $("library-conversations").setAttribute("aria-pressed", String(kind === "conversations"));
  $("library-grok").setAttribute("aria-pressed", String(kind === "grok"));
  $("library-files").setAttribute("aria-pressed", String(kind === "files"));
  $("library-pages").setAttribute("aria-pressed", String(kind === "pages"));
  $("page-new").hidden = Boolean(scope) || kind !== "pages";
  $("file-view").hidden = true;
  ++app.fileRequest;
  clearFilePreview();
  app.file = null;
  app.fileGroup = null;
}

async function showLibrary(kind = "snapshots", focusPin = null) {
  const scope = app.libraryScope;
  app.libraryKind = kind;
  const conversations = kind === "conversations";
  const grok = kind === "grok";
  const files = kind === "files";
  const pages = kind === "pages";
  const request = ++app.libraryRequest;
  app.archive = null;
  libraryTab(kind);
  $("library-items").hidden = false;
  $("library-items").replaceChildren();
  $("snapshot-view").hidden = true;
  $("archive-view").hidden = true;
  const label = grok ? "Grok Bot history" : kind;
  show("library-notice", `Loading ${label}…`);
  try {
    const query = scope && new URLSearchParams(scope.query);
    if (query && kind !== "results") query.set("kind", {pages:"page",files:"file",snapshots:"snapshot"}[kind]);
    const items = await api(query ? "/api/library/agent?" + query : grok ? "/api/grok-imports" : pages ? "/api/pages"
      : conversations ? "/api/library/conversations" : files ? "/api/library/files" : "/api/library");
    if (request !== app.libraryRequest) return;
    const rows = items.map((item) => {
      const row = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = conversations || grok ? item.agent : item.title;
      const detail = document.createElement("small");
      detail.textContent = scope ? ({page:`Page · Revision ${item.revision}`,file:"File",snapshot:"Snapshot"}[item.kind] + " · " + displayDate(item.at_ms))
        : pages ? `Revision ${item.revision} · ${displayDate(item.updated_ms)}`
        : grok ? (item.is_group ? "Group archive" : "Agent archive")
        : conversations ? displayDate(item.at_ms) : `${item.agent} · ${displayDate(item.at_ms)}`;
      if (item.pinned) detail.textContent = "Pinned · " + detail.textContent;
      button.append(detail);
      button.addEventListener("click", () => {
        if (scope ? item.kind === "page" : pages) void window.workspacePages.open(item.id);
        else if (conversations || grok) showArchive(item);
        else if (scope ? item.kind === "file" : files) void showFile(item.id, null, Boolean(scope));
        else void showSnapshot(item.id, Boolean(scope));
      });
      row.append(button);
      if (!conversations && !grok) {
        const resultKind = scope ? item.kind : pages ? "page" : files ? "file" : "snapshot";
        const pin = document.createElement("button");
        pin.type = "button";
        pin.className = "library-pin";
        pin.dataset.pinKey = `${resultKind}:${item.id}`;
        pin.textContent = item.pinned ? "Unpin" : "Pin";
        pin.setAttribute("aria-label", `${pin.textContent} ${item.title}`);
        pin.addEventListener("click", () => void changeLibraryPin(item, resultKind, pin, scope, kind));
        row.classList.add("library-result");
        row.append(pin);
      }
      return row;
    });
    $("library-items").replaceChildren(...rows);
    show("library-notice", rows.length ? "" : scope ? `No saved ${label} for this agent.` : `No saved ${label} yet.`);
    if ($("library").open && rows.length) {
      const pin = focusPin && [...$("library-items").querySelectorAll(".library-pin")].find((button) => button.dataset.pinKey === focusPin);
      if (pin) pin.focus();
      else if (!$("library").contains(document.activeElement)) rows[0].firstChild.focus();
    }
  } catch (error) {
    if (request === app.libraryRequest) show("library-notice", error.message);
  }
}

async function changeLibraryPin(item, resultKind, button, scope, listKind) {
  const sameList = () => $("library").open && !$("library-items").hidden
    && app.libraryScope === scope && app.libraryKind === listKind;
  button.disabled = true;
  try {
    const {pinned} = await api(`/api/library/pins/${resultKind}/${item.id}`, {pinned:!item.pinned});
    if (sameList()) {
      $("library-pin-status").textContent = `${item.title} ${pinned ? "pinned" : "unpinned"}.`;
      await showLibrary(listKind, button.dataset.pinKey);
    }
  } catch (error) {
    if (sameList()) show("library-notice", error.message);
  } finally {
    button.disabled = false;
  }
}

async function showSnapshot(id, keepScope = false) {
  const request = ++app.libraryRequest;
  if (!keepScope) app.libraryScope = null;
  libraryTab(app.libraryScope ? app.libraryKind : "snapshots");
  $("library-back").textContent = app.libraryScope ? "Back to results" : "Back to snapshots";
  $("library-items").hidden = true;
  $("archive-view").hidden = true;
  $("snapshot-view").hidden = false;
  $("snapshot-title").textContent = "";
  $("snapshot-text").textContent = "";
  $("library-back").focus();
  show("library-notice", "Loading snapshot…");
  try {
    const snapshot = await api(`/api/library/${id}`);
    if (request !== app.libraryRequest) return;
    $("snapshot-title").textContent = snapshot.detail;
    $("snapshot-text").textContent = snapshot.text;
    show("library-notice", "");
  } catch (error) {
    if (request === app.libraryRequest) show("library-notice", error.message);
  }
}

function clearFilePreview() {
  app.filePdf?.abort();
  app.filePdf = null;
  $("file-pdf-view").replaceChildren();
  $("file-pdf-view").hidden = true;
  if (app.filePreviewUrl) URL.revokeObjectURL(app.filePreviewUrl);
  app.filePreviewUrl = null;
  $("file-image").removeAttribute("src");
  $("file-image-view").hidden = $("file-zoom").hidden = true;
  $("file-image-view").classList.remove("actual");
  $("file-zoom").textContent = "Actual size";
  $("file-zoom").setAttribute("aria-pressed", "false");
  $("file-media-view").hidden = true;
  for (const id of ["file-video", "file-audio"]) {
    const player = $(id);
    player.onloadedmetadata = player.onerror = null;
    if (player.hasAttribute("src")) {
      player.pause();
      player.removeAttribute("src");
      player.load();
    }
    player.hidden = true;
  }
}

$("file-zoom").addEventListener("click", () => {
  const actual = $("file-image-view").classList.toggle("actual");
  $("file-zoom").setAttribute("aria-pressed", String(actual));
  $("file-zoom").textContent = actual ? "Fit image" : "Actual size";
});

function showTable(preview) {
  const table = document.createElement("table");
  const head = table.createTHead().insertRow();
  for (const [index, name] of preview.headers.entries()) {
    const cell = document.createElement("th");
    cell.scope = "col";
    cell.textContent = name || `Column ${index + 1}`;
    head.append(cell);
  }
  const body = table.createTBody();
  for (const values of preview.rows) {
    const row = body.insertRow();
    for (const value of values) row.insertCell().textContent = value;
  }
  $("file-table").replaceChildren(table);
  $("file-table").hidden = false;
}

function fileNotice(message) {
  show($("sent-file-dialog").open ? "sent-file-notice" : "library-notice",message);
}

async function showImage(path, name, request) {
  const response = await fetch(path, { headers: { Authorization: "Bearer " + app.token } });
  if (!response.ok) throw new Error("Image unavailable.");
  const data = await response.blob();
  if (request !== app.fileRequest) return;
  app.filePreviewUrl = URL.createObjectURL(data);
  const image = $("file-image");
  image.alt = name;
  image.src = app.filePreviewUrl;
  await image.decode();
  if (request === app.fileRequest) $("file-image-view").hidden = $("file-zoom").hidden = false;
}

async function showMedia(path, file, request) {
  const player = $(file.media.kind === "audio" ? "file-audio" : "file-video");
  const unavailable = () => {
    if (request !== app.fileRequest) return;
    clearFilePreview();
    fileNotice("This recording couldn’t be played here. You can still download the original.");
  };
  try {
    fileNotice("Loading recording…");
    const response = await fetch(path, { headers: { Authorization: "Bearer " + app.token } });
    if (!response.ok) return unavailable();
    const data = await response.blob();
    if (request !== app.fileRequest) return;
    app.filePreviewUrl = URL.createObjectURL(data.slice(0, data.size, file.media.mime));
    player.setAttribute("aria-label", file.name);
    player.onerror = unavailable;
    player.onloadedmetadata = () => {
      if (request !== app.fileRequest) return;
      player.hidden = $("file-media-view").hidden = false;
      fileNotice("");
    };
    player.src = app.filePreviewUrl;
  } catch {
    unavailable();
  }
}

async function showPdf(path, request) {
  const controller = new AbortController();
  app.filePdf = controller;
  const { signal } = controller;
  const unavailable = (error) => {
    if (signal.aborted || request !== app.fileRequest) return;
    clearFilePreview();
    fileNotice(error?.name === "PasswordException"
      ? "This PDF is password protected. Download the original to open it."
      : "This PDF couldn’t be previewed. You can still download the original.");
  };
  try {
    fileNotice("Loading PDF…");
    const [viewer, response] = await Promise.all([
      import("/pdf-preview.js"),
      fetch(path, { headers: { Authorization: "Bearer " + app.token }, signal }),
    ]);
    if (!response.ok) return unavailable();
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (signal.aborted || request !== app.fileRequest) return;
    await viewer.openPdf(bytes, $("file-pdf-view"), signal, unavailable, () => fileNotice(""));
  } catch (error) {
    unavailable(error);
  }
}

async function showFile(id, group = null, keepScope = false) {
  if (!keepScope) app.libraryScope = null;
  libraryTab(app.libraryScope ? app.libraryKind : "files");
  app.fileGroup = group;
  $("files-back").textContent = app.libraryScope ? "Back to results" : group === null ? "Back to files" : "Back to group";
  $("library-items").hidden = true;
  $("archive-view").hidden = true;
  $("snapshot-view").hidden = true;
  const base = group === null ? `/api/library/files/${id}` : `/api/groups/${group}/files/${id}`;
  return showSavedFile(group === null ? base : base + "/info", group === null ? base + "/download" : base, base + "/image",
    group === null ? {kind:"library", id} : {kind:"group", group, id});
}

function showSentFile(base,source) {
  const dialog = $("sent-file-dialog");
  if (dialog.open || !app.authorized) return;
  clearFilePreview();
  $("file-title").textContent = "Attachment";
  dialog.append($("file-view"));
  $("files-back").textContent = "Back to conversation";
  dialog.showModal();
  return showSavedFile(base + "/info",base,base + "/image",source);
}

$("sent-file-dialog").addEventListener("close", () => {
  if ($("sent-file-dialog").open) return;
  ++app.fileRequest;
  app.file = null;
  clearFilePreview();
  $("file-view").hidden = true;
  $("library-file-slot").append($("file-view"));
  show("sent-file-notice","");
});

async function showSavedFile(info,download,image,source) {
  const request = ++app.fileRequest;
  app.file = null;
  $("file-view").hidden = false;
  $("file-title").textContent = "";
  $("file-description").textContent = "";
  $("file-text").textContent = "";
  $("file-text").hidden = true;
  $("file-table").replaceChildren();
  $("file-table").hidden = true;
  $("file-download").disabled = true;
  $("file-save-connected").hidden = true;
  $("files-back").focus();
  fileNotice("Loading file…");
  try {
    const file = await api(info);
    if (request !== app.fileRequest) return;
    app.file = { name: file.name, download, source };
    $("file-title").textContent = file.name;
    const size = file.bytes < 1024 ? `${file.bytes} bytes` : `${(file.bytes / 1024).toFixed(1)} KB`;
    $("file-description").textContent = file.image ? `${file.image.width} × ${file.image.height} · ${size}`
      : file.table ? `CSV · ${size}${file.table.truncated ? " · Partial preview" : ""}`
      : file.media ? `${file.media.label} · ${size}`
      : file.pdf ? `PDF · ${size}`
      : file.preview === null ? `${size} · Download to view` : size;
    $("file-text").hidden = file.preview === null;
    $("file-text").textContent = file.preview;
    $("file-download").disabled = false;
    void window.connectedFiles.canSave().then((uploads) => {
      if (request === app.fileRequest) $("file-save-connected").hidden = !uploads;
    }).catch(() => {});
    fileNotice("");
    if (file.table) showTable(file.table);
    if (file.image) {
      try {
        fileNotice("Loading image…");
        await showImage(image, file.name, request);
        if (request === app.fileRequest) fileNotice("");
      } catch {
        if (request === app.fileRequest) {
          clearFilePreview();
          fileNotice("This image couldn’t be displayed. The original is still available to download.");
        }
      }
    } else if (file.media) await showMedia(app.file.download, file, request);
    else if (file.pdf) await showPdf(app.file.download, request);
  } catch (error) {
    if (request === app.fileRequest) fileNotice(error.message);
  }
}

async function downloadBlob(path, name, current = () => true) {
  const response = await fetch(path, { headers: { Authorization: "Bearer " + app.token } });
  if (!response.ok) throw Object.assign(new Error(`Download failed (HTTP ${response.status}).`), {status:response.status});
  const data = await response.blob();
  if (!current()) return;
  const link = document.createElement("a");
  link.href = URL.createObjectURL(data);
  link.download = name || decodeURIComponent(response.headers.get("Content-Disposition")?.split("filename*=UTF-8''")[1] || "conversation.txt");
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}

async function downloadTranscript(button, path, notice, current) {
  if (button.disabled) return;
  button.disabled = true;
  show(notice, "Preparing transcript…");
  try {
    await downloadBlob(path, null, current);
    if (current()) show(notice, "");
  } catch (error) {
    if (current()) show(notice, error.status === 413 ? "This conversation exceeds the 16 MiB transcript limit."
      : "The transcript couldn’t be downloaded. Try again.");
  } finally {
    if (current()) button.disabled = false;
  }
}

$("archive-transcript").addEventListener("click", () => {
  const archive = app.archive;
  if (!archive || !$("library").open) return;
  const {core, address, created_ms} = archive.item;
  void downloadTranscript($("archive-transcript"), `/api/history/${encodeURIComponent(core)}/${encodeURIComponent(address)}/${created_ms}/transcript`,
    "library-notice", () => app.archive === archive && $("library").open && !$("archive-view").hidden);
});

$("file-download").addEventListener("click", async () => {
  const file = app.file;
  const request = app.fileRequest;
  if (!file) return;
  $("file-download").disabled = true;
  try {
    await downloadBlob(file.download, file.name, () => request === app.fileRequest);
  } catch {
    if (request === app.fileRequest) fileNotice("The file couldn’t be downloaded. Try again.");
  } finally {
    if (request === app.fileRequest) $("file-download").disabled = false;
  }
});

$("file-save-connected").addEventListener("click", () => {
  if (!app.file) return;
  const request = app.fileRequest;
  window.connectedFiles.save(app.file, (saved) => {
    if (request === app.fileRequest) fileNotice("Saved a copy to the connected folder: " + saved.path);
  });
});

function archiveAttachmentList(names, archive, request) {
  const list = document.createElement("ul");
  list.className = "group-files";
  list.setAttribute("aria-label", "Archived attachments");
  const current = () => request === app.libraryRequest && $("library").open;
  for (const name of names) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = name;
    button.setAttribute("aria-label", "Download " + name);
    button.addEventListener("click", async () => {
      button.disabled = true;
      show("library-notice", "");
      try {
        await downloadBlob(`/api/grok-imports/${archive}/attachments/${encodeURIComponent(name)}`, name, current);
      } catch {
        if (current()) show("library-notice", "The attachment couldn’t be downloaded. Try again.");
      } finally {
        button.disabled = false;
      }
    });
    item.append(button);
    list.append(item);
  }
  return list;
}

function showArchive(item, match = null) {
  app.libraryScope = null;
  ++app.libraryRequest;
  app.archive = { item, match, before: null, loading: false };
  const imported = item.core === "import:grok-bot";
  libraryTab(imported ? "grok" : "conversations");
  $("archive-back").textContent = imported ? "Back to Grok Bot history" : "Back to conversations";
  $("library-items").hidden = true;
  $("snapshot-view").hidden = true;
  $("archive-view").hidden = false;
  $("archive-title").textContent = item.agent;
  $("archive-transcript").disabled = false;
  $("archive-items").replaceChildren();
  $("archive-before").hidden = true;
  $("archive-latest").hidden = match == null;
  $("archive-back").focus();
  void readArchive();
}

async function readArchive(older = false) {
  const archive = app.archive;
  if (!archive || archive.loading) return;
  const { item, before } = archive;
  const request = app.libraryRequest;
  archive.loading = true;
  $("archive-before").disabled = true;
  show("library-notice", "Loading messages…");
  try {
    const cursor = older ? before : archive.match == null ? null : archive.match + 1;
    const path = `/api/history/${encodeURIComponent(item.core)}/${item.address}/${item.created_ms}`;
    const page = await api(path + (cursor ? "?before=" + cursor : ""));
    if (request !== app.libraryRequest) return;
    const original = (id) => { if (!focusMessage($("archive-items"), id)) showArchive(item, id); };
    const thread = { path, core:item.core, key:item.address + "/" + item.created_ms, name:item.agent };
    const imported = item.core === "import:grok-bot";
    const archiveId = imported ? /^archive-(\d+)$/.exec(item.address)?.[1] : null;
    const rows = page.items.map((entry) => {
      const row = historyRow(entry, false, imported, path, original, null, thread);
      if (archiveId && entry.attachments?.length) row.append(archiveAttachmentList(entry.attachments, archiveId, request));
      return row;
    });
    if (older) $("archive-items").prepend(...rows);
    else $("archive-items").replaceChildren(...rows);
    if (archive.match != null && !older) {
      focusMessage($("archive-items"), archive.match);
    }
    archive.before = page.before;
    $("archive-before").hidden = !page.before;
    show("library-notice", rows.length ? "" : "No saved messages.");
  } catch (error) {
    if (request === app.libraryRequest) show("library-notice", error.message);
  } finally {
    if (request === app.libraryRequest) {
      archive.loading = false;
      $("archive-before").disabled = false;
    }
  }
}

$("save-output").addEventListener("click", () => {
  if (!active() || !app.outputReady) return;
  app.saveTarget = { key: app.selected, core: app.historyCore };
  $("snapshot-name").value = `${title(active())} output`;
  show("save-error", "");
  $("save-dialog").showModal();
  $("snapshot-name").select();
});
$("save-cancel").addEventListener("click", () => { if (!app.saving) $("save-dialog").close(); });
$("save-dialog").addEventListener("cancel", (event) => { if (app.saving) event.preventDefault(); });
$("save-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (app.saving || !app.saveTarget) return;
  if (!app.online || app.core !== app.saveTarget.core) {
    show("save-error", "Reconnect to the agent’s Herdr Core before saving.");
    return;
  }
  app.saving = true;
  $("save-submit").disabled = true;
  $("save-cancel").disabled = true;
  show("save-error", "");
  try {
    await api(`/api/agents/${app.saveTarget.key}/snapshots`, { title: $("snapshot-name").value });
    $("save-dialog").close();
    show("notice", "Snapshot saved to your Library.");
    void readHistory();
  } catch (error) {
    show("save-error", error.message);
  } finally {
    app.saving = false;
    $("save-submit").disabled = false;
    $("save-cancel").disabled = false;
  }
});

$("launch-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (app.launching) return;
  const task = $("first-task").value;
  if (!taskOk(task)) { show("launch-error", "Enter a task with up to 16 KB of plain text."); return; }
  const useSaved = $("include-instructions").checked ? app.launchInstructions : null;
  const initial = app.launchProfile === null ? $("first-instructions").value : "";
  if (new TextEncoder().encode(initial).length > 6144) {
    show("launch-error", "Use up to 6 KiB of plain text for standing instructions.");
    return;
  }
  if (!taskOk(launchInstructionMessage(task, useSaved?.text || initial.trim()))) {
    show("launch-error", "The first task and standing instructions together must fit within 16 KiB.");
    return;
  }
  app.launching = true;
  for (const field of $("launch-form").elements) field.disabled = true;
  $("start").textContent = "Starting…";
  show("launch-error", "");
  try {
    const agent = await api("/api/agents", {
      name: $("name").value, template: $("template").value, task, profile_id: app.launchProfile,
      expected_runtime: selectedTemplate()?.runtime,
      model_choice: selectedModel(),
      model_id: selectedModelId(),
      collect_results: $("collect-results").checked,
      standing_instructions: initial || undefined,
      instructions_revision: useSaved?.revision,
    });
    const key = idOf(agent);
    ++app.change;
    if (app.core === agent.core) app.agents = [agent, ...app.agents.filter((item) => idOf(item) !== key)];
    await window.agentProfiles.load().catch(() => {});
    app.linkedFirstTasks.delete(app.launchProfile);
    app.launchLinkedProfile = null;
    $("launch-form").reset();
    finishFirstProfileLaunch(true);
    $("launch").close();
    select(key, agent.core, agent.profile_id);
    $("conversation").focus();
    show("notice", agent.open_code_first_task
      ? agent.first_message?.sent
        ? "OpenCode accepted the first task."
        : agent.first_message?.reason || "Check the conversation before resending the first task."
      : agent.first_message?.sent ? "" : `The agent started, but Herdr did not send its first task.${agent.first_message?.reason ? " " + agent.first_message.reason : ""}`);
  } catch (error) {
    show("launch-error", error.message);
  } finally {
    app.launching = false;
    for (const field of $("launch-form").elements) field.disabled = false;
    $("start").textContent = "Start agent";
    void refresh();
  }
});

$("task").addEventListener("input", () => {
  if (app.selected) {
    const key = draftKey();
    app.drafts.set(key, $("task").value);
    saveDirectDraft(key);
  }
  renderState();
});

$("direct-cancel-reply").addEventListener("click", () => {
  app.replyDrafts.delete(draftKey());
  saveDirectDraft(draftKey());
  show("composer-error", "");
  renderState();
  $("task").focus();
});

$("attach").addEventListener("click", () => $("attachment-picker").click());
$("attachment-picker").addEventListener("change", (event) => {
  const files = [...event.target.files];
  event.target.value = "";
  attachLocalFiles(files);
});

bindComposerFiles($("composer"), $("task"), canStageAttachment, attachLocalFiles,
  (message) => show("composer-error", message));

function attachLocalFiles(files) {
  if (!files.length || !canStageAttachment()) return;
  queueDirectFiles(files, (message) => show("composer-error",message));
}

function directDictationDraft() {
  if (!app.authorized || !app.online || !live(active()) || window.groupWorkspace?.active()) return null;
  const field = $("task");
  return {key:draftKey(), field, canEdit:!field.disabled,
    limit:(fileDraft().files.length ? 12 : replyDraft() ? 14 : 16) * 1024};
}

function directAttachmentDraft() {
  if (!app.authorized || !app.online || !app.attachments || !live(active())
    || window.groupWorkspace?.active()) return null;
  const {files} = fileDraft();
  return {key:draftKey(), canAdd:canStageAttachment(),
    bytes:files.length >= 4 ? 0 : 8 * 1024 * 1024 - files.reduce((sum, file) => sum + file.size, 0)};
}

function addDirectDraftAttachment(key, file) {
  const target = directAttachmentDraft();
  if (!target?.canAdd || key !== target.key || file.size > target.bytes) return false;
  return queueDirectFiles([file], (message) => show("composer-error",message));
}

const voiceDirectDraft = directAttachmentDraft;
const addDirectVoiceMemo = addDirectDraftAttachment;

function queueDirectFiles(files, onError) {
  const key = draftKey();
  const old = fileDraft(key);
  const next = [...old.files,...files];
  if (next.length > 4) { onError("Attach up to four files per direct task."); return false; }
  if (next.reduce((sum,file) => sum + file.size,0) > 8 * 1024 * 1024) {
    onError("Task attachments must total 8 MiB or less."); return false;
  }
  const missing = [...old.missing];
  for (const file of files) {
    const index = missing.indexOf(file.name);
    if (index >= 0) missing.splice(index,1);
  }
  app.directFiles.set(key,{files:next,missing});
  saveDirectDraft(key);
  show("composer-error", "");
  renderState();
  return true;
}

let renderedDirectFiles;
let directFilesBusy;
function renderDirectFiles(draft) {
  const list = $("direct-draft-files");
  $("direct-missing-files").hidden = !draft.missing.length;
  const missing = draft.missing.length ? "Select these files again: " + draft.missing.join(", ") + "." : "";
  if ($("direct-missing-label").textContent !== missing) show("direct-missing-label",missing);
  $("direct-ignore-missing").disabled = app.busy || app.attaching;
  list.hidden = !draft.files.length;
  if (renderedDirectFiles === draft && directFilesBusy === app.busy) return;
  renderedDirectFiles = draft;
  directFilesBusy = app.busy;
  const key = draftKey();
  list.replaceChildren(...draft.files.map((file,index) => {
    const row = document.createElement("li");
    row.className = "draft-file";
    const name = document.createElement("span");
    name.textContent = file.name;
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "Remove";
    remove.setAttribute("aria-label",`Remove ${file.name}`);
    remove.disabled = app.busy;
    remove.addEventListener("click", () => {
      if (app.busy || key !== draftKey()) return;
      app.directFiles.set(key,{...draft,files:draft.files.filter((_,i) => i !== index)});
      saveDirectDraft(key);
      show("composer-error","");
      renderState();
      if (!$("attach").disabled && !$("attach").hidden) $("attach").focus();
    });
    row.append(name,remove);
    return row;
  }));
}

$("direct-ignore-missing").addEventListener("click", () => {
  if ($("direct-ignore-missing").disabled) return;
  const key = draftKey();
  app.directFiles.set(key,{...fileDraft(key),missing:[]});
  saveDirectDraft(key);
  renderState();
  if (!$("task").disabled) $("task").focus();
});

function bindComposerFiles(form, task, canAttach, addFiles, showError) {
  const hint = form.querySelector(".composer-drop-hint");
  const ready = () => !form.hidden && canAttach();
  const fileDrag = (event) => Array.from(event.dataTransfer?.types || []).includes("Files");
  const clear = () => { hint.hidden = true; };
  form.addEventListener("dragover", (event) => {
    if (!fileDrag(event)) return;
    event.preventDefault();
    hint.hidden = !ready();
    event.dataTransfer.dropEffect = hint.hidden ? "none" : "copy";
  });
  form.addEventListener("dragleave", (event) => {
    if (!(event.relatedTarget instanceof Node) || !form.contains(event.relatedTarget)) clear();
  });
  form.addEventListener("drop", (event) => {
    clear();
    if (!fileDrag(event)) return;
    event.preventDefault();
    if (!ready()) return;
    if ([...event.dataTransfer.items].some((item) => item.kind === "file" && item.webkitGetAsEntry?.()?.isDirectory)) {
      showError("Drop individual files instead of a folder.");
      return;
    }
    void addFiles([...event.dataTransfer.files]);
  });
  window.addEventListener("dragend", clear);
  task.addEventListener("paste", (event) => {
    const clipboard = event.clipboardData;
    if (!clipboard || !ready() || clipboard.getData("text/plain")) return;
    const files = clipboard.files.length ? [...clipboard.files]
      : Array.from(clipboard.items, (item) => item.kind === "file" ? item.getAsFile() : null).filter(Boolean);
    if (!files.length) return;
    event.preventDefault();
    void addFiles(files);
  });
}

function canStageAttachment() {
  return !app.attaching && !app.busy && app.attachments && app.online && live(active());
}

async function queueConnectedFile(request, onError) {
  if (!canStageAttachment()) return false;
  const core = app.core;
  const token = app.token;
  const draftId = draftKey();
  const current = () => draftKey() === draftId;
  app.attaching = true;
  show("composer-error", "");
  renderState();
  try {
    const file = await request();
    if (core !== app.core || token !== app.token || !app.authorized || !current()) {
      throw new Error("The workspace connection changed before this draft was updated.");
    }
    return queueDirectFiles([file],onError);
  } catch (error) {
    if (onError) onError(error.message);
    else if (current()) show("composer-error", error.message);
    else show("notice", error.message);
    return false;
  } finally {
    app.attaching = false;
    renderState();
    if (current() && !$("task").disabled) $("task").focus();
  }
}

$("composer").addEventListener("submit", async (event) => {
  event.preventDefault();
  const agent = active();
  if ($("send").disabled || !agent) return;
  const key = idOf(agent);
  const draftId = draftKey();
  const current = () => draftKey() === draftId;
  const task = $("task").value;
  const files = fileDraft(draftId).files;
  const quote = replyDraft();
  const reply_to = quote ? {id:quote.id, core:app.historyCore} : undefined;
  app.busy = true;
  show("composer-error", "");
  renderState();
  try {
    const path = `/api/agents/${key}/messages`;
    const message = {text:task, reply_to, expected_core:app.core};
    if (files.length) {
      const upload = new FormData();
      upload.append("message", JSON.stringify(message));
      for (const file of files) upload.append("file",file);
      await api(path + "/with-files",upload);
    } else await api(path,message);
    app.drafts.delete(draftId);
    app.replyDrafts.delete(draftId);
    app.directFiles.delete(draftId);
    saveDirectDraft(draftId);
    if (current()) $("task").value = "";
  } catch (error) {
    if (current()) show("composer-error", error.message);
    else show("notice", `${title(agent)}: ${error.message}`);
  } finally {
    app.busy = false;
    renderState();
    if (current() && !$("task").disabled) $("task").focus();
    if (current()) void readHistory();
    void refresh();
  }
});

async function control(action) {
  const agent = active();
  if (app.busy || !live(agent) || !app.online) return;
  if (action === "end" && !confirm(`End the running session for ${title(agent)}? Its process will stop.`)) return;
  app.busy = true;
  show("notice", "");
  renderState();
  try {
    const result = await api(`/api/agents/${idOf(agent)}/${action}`, {});
    if (action === "end") {
      ++app.change;
      app.agents = app.agents.map((item) => idOf(item) === idOf(agent) ? result : item);
      show("notice", "Herdr ended the session.");
    } else {
      show("notice", ({ stopped: "Herdr observed the task stop.", exited: "The agent process exited.",
        still_working: "Herdr sent the interrupt. The agent still reported working.",
        unknown: "Herdr sent the interrupt. The agent did not report whether it stopped." })[result.outcome]
        || "Herdr sent the interrupt.");
    }
  } catch (error) {
    show("notice", error.message);
  } finally {
    app.busy = false;
    renderState();
    void refresh();
  }
}
$("interrupt").addEventListener("click", () => control("interrupt"));
$("end").addEventListener("click", () => control("end"));

document.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k" && !$("launch").open) {
    if (!$("workspace-search").open && document.querySelector("dialog[open]")) return;
    event.preventDefault();
    if (app.authorized) window.workspaceSearch?.open();
    else $("unlock").focus();
  }
  if ((event.metaKey || event.ctrlKey) && event.key === "Enter" && event.target === $("task") && !$("send").disabled) {
    event.preventDefault();
    $("composer").requestSubmit();
  }
  if (event.key === "Escape" && !$("details").hidden && !document.querySelector("dialog[open]")) {
    toggleDetails(false);
    $("details-toggle").focus();
  }
});

void refresh();
setInterval(() => { if (!document.hidden) void refresh(); }, 2500);
document.addEventListener("visibilitychange", () => { if (!document.hidden) void refresh(); });
