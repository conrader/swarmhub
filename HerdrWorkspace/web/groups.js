(() => {
  "use strict";
  const state = { groups: [], view: null, rosterKey: null, fetching: false, changing: false, editor: null, drafts: new Map(), sending: new Set(), revision: 0 };
  const fileLimit = 8 * 1024 * 1024;
  const opened = () => state.groups.find((group) => group.id === state.view?.id);
  const connected = (group) => app.online && app.core === group?.core;
  const qualified = () => app.agents.filter(live);
  const target = (member) => ({ address: member.address, created_ms: member.created_ms });
  let formRequest = null;
  let formSending = false;

  function stashDraft() {
    const view = state.view;
    if (!view) return;
    const text = $("group-task").value;
    state.drafts.set(view.slot, { text, files: view.files,
      recipients: view.recipients, reply: view.reply, missing: view.missing });
    const recipients = [...view.recipients];
    const missing = [...view.missing, ...view.files.map((file) => file.name)];
    const { id, author, text: original, target, is_question, answer_state } = view.reply || {};
    const reply = view.reply ? { id, author, text: original.slice(0, 320), target, is_question, answer_state } : null;
    saveTabDraft("group", view.slot, text || reply || recipients.length || missing.length
      ? { text, recipients, reply, missing } : null);
  }

  function leave() {
    if (!state.view) return;
    stashDraft();
    state.view = null;
  }

  function open(id) {
    const group = state.groups.find((item) => item.id === id);
    if (!group) return;
    if (state.view?.id !== id) {
      select(null);
      const slot = JSON.stringify([group.core, group.id]);
      const draft = state.drafts.get(slot) ?? readTabDraft("group", slot);
      state.view = { id, slot, entries: [], before: null, paged: false, sequence: 0, older: false,
        first: true, signature: null, recipients: new Set(draft?.recipients || []), choiceKey: null,
        files: draft?.files || [], missing: draft?.missing || [], filesKey: null,
        suggestions: null, reply: draft?.reply || null };
      $("group-task").value = draft?.text || "";
      $("group-transcript").disabled = false;
      $("group-messages").replaceChildren();
      showDrafts(state.view, []);
      show("group-error", "");
    }
    $("workspace").dataset.mobileView = "agent";
    renderState();
    $("conversation").focus();
    void read();
  }

  function renderRoster(filter) {
    const groups = state.groups.filter((group) => group.name.toLowerCase().includes(filter));
    $("group-roster").hidden = groups.length === 0;
    const key = JSON.stringify(groups.map(({id, name, members}) => [id, name, members.length]));
    if (state.rosterKey !== key) {
      const old = new Map(Array.from($("groups").children, (button) => [Number(button.dataset.group), button]));
      for (const [index, group] of groups.entries()) {
        let button = old.get(group.id);
        if (!button) {
          button = document.createElement("button");
          button.type = "button";
          button.className = "agent";
          button.dataset.group = group.id;
          button.addEventListener("click", () => open(group.id));
          const avatar = document.createElement("span");
          avatar.className = "avatar";
          avatar.textContent = "#";
          avatar.setAttribute("aria-hidden", "true");
          const copy = document.createElement("span");
          copy.className = "agent-copy";
          copy.append(document.createElement("strong"), document.createElement("small"));
          const unread = document.createElement("span");
          unread.className = "unread-marker";
          unread.hidden = true;
          button.append(avatar, copy, unread);
        }
        button.querySelector("strong").textContent = group.name;
        button.querySelector("small").textContent = `${group.members.length} agents`;
        if ($("groups").children[index] !== button) $("groups").insertBefore(button, $("groups").children[index] || null);
        old.delete(group.id);
      }
      for (const button of old.values()) button.remove();
      state.rosterKey = key;
    }
    for (const button of $("groups").children) {
      if (Number(button.dataset.group) === state.view?.id) button.setAttribute("aria-current", "true");
      else button.removeAttribute("aria-current");
      window.workspaceActivity?.badge(button.querySelector(".unread-marker"), window.workspaceActivity.groupCount(Number(button.dataset.group)));
    }
  }

  function option(member, name, checked, unavailable, toggled, caption = member.name) {
    const label = document.createElement("label");
    label.className = "person";
    const field = document.createElement("input");
    field.type = "checkbox";
    field.name = name;
    field.value = idOf(member);
    field.checked = checked;
    field.disabled = unavailable;
    if (toggled) field.addEventListener("change", () => toggled(field));
    const text = document.createElement("span");
    text.textContent = caption;
    label.append(field, text);
    return label;
  }

  function choicesFor(group) {
    const running = new Set(connected(group) ? qualified().map(idOf) : []);
    return group.members.map((member) => ({ member, key: idOf(member), running: running.has(idOf(member)) }));
  }

  function mentionedChoices(text, choices) {
    const mentioned = new Set();
    for (const [, raw] of text.matchAll(/(?:^|[\s([{>])@([a-z0-9._-]+)/gi)) {
      const literal = raw.toLowerCase();
      const find = (name) => choices.filter(({ member }) => member.name.toLowerCase() === name);
      const exact = find(literal);
      const normalized = literal.replace(/\.+$/, "");
      if (normalized === "everyone") choices.filter((choice) => choice.running).forEach(({key}) => mentioned.add(key));
      else {
        const candidates = exact.length ? exact : find(normalized);
        if (candidates.length === 1) mentioned.add(candidates[0].key);
      }
    }
    return mentioned;
  }

  function routing(view, choices, text) {
    if (view.reply) {
      const source = view.entries.find((item) => item.id === view.reply.id) || view.reply;
      const selected = choices.filter(({key}) => key === idOf(source.target));
      return { mentioned: new Set(), selected, unavailable: selected.filter((item) => !item.running),
        closed: Boolean(source.is_question && source.answer_state && source.answer_state !== "not_sent") };
    }
    const mentioned = mentionedChoices(text, choices);
    const selected = choices.filter(({key}) => view.recipients.has(key) || mentioned.has(key));
    return { mentioned, selected, unavailable: selected.filter((choice) => !choice.running) };
  }

  function mentionFragment() {
    const task = $("group-task");
    if (task.selectionStart !== task.selectionEnd || /[a-z0-9._-]/i.test(task.value[task.selectionEnd] || "")) return null;
    const end = task.selectionStart;
    const match = task.value.slice(0, end).match(/(?:^|[\s([{>])@([a-z0-9._-]*)$/i);
    return match ? { start: end - match[1].length - 1, end, query: match[1].toLowerCase() } : null;
  }

  function renderSuggestions(view, choices, disabled) {
    const fragment = mentionFragment();
    const task = $("group-task");
    const box = $("group-mentions");
    const key = fragment ? JSON.stringify([task.value, fragment.end]) : null;
    const names = ["everyone", ...choices.filter(({member, running}) => running
      && member.name.toLowerCase() !== "everyone" && /^[a-z0-9._-]+$/i.test(member.name)
      && choices.filter((choice) => choice.member.name.toLowerCase() === member.name.toLowerCase()).length === 1
    ).map(({member}) => member.name)];
    const options = fragment && key !== view.dismissed && !disabled
      && (document.activeElement === task || box.contains(document.activeElement))
      ? names.filter((name) => name.toLowerCase().startsWith(fragment.query)) : [];
    const signature = JSON.stringify([key, options]);
    if (view.suggestions !== signature) {
      view.suggestions = signature;
      box.replaceChildren(...options.map((name) => {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = name === "everyone" ? "@everyone · all running members" : "@" + name;
        button.addEventListener("click", () => {
          task.setRangeText("@" + name + " ", fragment.start, fragment.end, "end");
          stashDraft();
          task.focus();
          render();
        });
        return button;
      }));
    }
    box.hidden = options.length === 0;
  }

  function render() {
    window.workspaceGroupHandoffs?.update();
    const group = opened();
    $("new-group").disabled = !app.online || qualified().length < 2;
    $("conversation").classList.toggle("group-open", Boolean(group));
    $("work-scroll").hidden = Boolean(group);
    $("group-panel").hidden = $("group-compose").hidden = !group;
    $("group-edit").hidden = !group;
    if (!group) return;
    $("title").textContent = group.name;
    $("badge").textContent = "#";
    $("headline").textContent = connected(group) ? group.members.map((member) => member.name).join(" · ")
      : "Conversation available · Herdr Core disconnected";
    const disabled = !connected(group) || state.sending.has(group.id);
    const choices = choicesFor(group);
    const text = $("group-task").value;
    const { mentioned, selected, unavailable, closed } = routing(state.view, choices, text);
    const reply = state.view.reply;
    $("group-recipient-field").hidden = Boolean(reply);
    $("group-mention-help").textContent = reply ? "Only the original agent receives this reply." : "Pick recipients above or type @ to mention them.";
    $("group-reply-target").hidden = !reply;
    $("group-cancel-reply").disabled = state.sending.has(group.id);
    if (reply) {
      $("group-reply-name").textContent = (reply.is_question ? "Answering " : "Replying to ") + reply.author;
      $("group-reply-excerpt").textContent = reply.text.slice(0, 320) || "Shared files";
    }
    const key = JSON.stringify(choices.map(({key, member}) => [key, member.name]));
    if (key !== state.view.choiceKey) {
      state.view.choiceKey = key;
      state.view.recipients = new Set([...state.view.recipients].filter((item) => choices.some((choice) => choice.key === item)));
      $("group-recipients").replaceChildren(...choices.map(({member}) => option(
        member, "recipient", false, false, (field) => {
          if (field.checked) state.view.recipients.add(field.value);
          else state.view.recipients.delete(field.value);
          stashDraft();
          render();
        }
      )));
    }
    for (const [index, {member, key, running}] of choices.entries()) {
      const row = $("group-recipients").children[index];
      const field = row.querySelector("input");
      field.checked = mentioned.has(key) || state.view.recipients.has(key);
      field.disabled = disabled || mentioned.has(key) || (!running && !field.checked);
      row.querySelector("span").textContent = member.name + (!running ? " (unavailable)" : mentioned.has(key) ? " (mentioned)" : "");
    }
    $("group-task").disabled = disabled;
    const route = closed ? "An answer is already recorded for this question."
      : reply && !selected.length ? "The original agent is no longer in this group."
      : unavailable.length ? "Unavailable: " + unavailable.map(({member}) => member.name).join(", ")
      : selected.length ? "Sending to: " + selected.map(({member}) => member.name).join(", ") : "";
    if ($("group-routing").textContent !== route) show("group-routing", route);
    renderSuggestions(state.view, choices, disabled || Boolean(reply));
    renderFiles(state.view, disabled);
    $("group-send").disabled = disabled || !taskOk(text) || new TextEncoder().encode(text).length > 8192
      || !selected.length || Boolean(unavailable.length) || closed || state.view.missing.length > 0
      || (state.view.files.length > 0 && !app.attachments);
    $("group-send").textContent = state.sending.has(group.id) ? "Sending…"
      : reply ? reply.is_question ? "Send answer" : "Send reply" : "Send task ↑";
    updateReplyButtons();
    window.voiceMemos?.render();
    window.dictation?.render();
  }

  function canReply(message) {
    const group = opened();
    return message?.target && connected(group)
      && !state.sending.has(group.id)
      && (!message.is_question || !message.answer_state || message.answer_state === "not_sent")
      && choicesFor(group).some(({key, running}) => running && key === idOf(message.target));
  }

  function updateReplyButtons() {
    for (const button of $("group-messages").querySelectorAll("[data-direct-reply]")) {
      const message = state.view.entries.find((item) => item.id === Number(button.dataset.directReply));
      button.disabled = !canReply(message);
    }
  }

  function openForm(message) {
    const group = opened();
    if (!canReply(message) || !message.form) return;
    formRequest = { group: group.id, message };
    $("group-input-title").textContent = message.form.title;
    $("group-input-recipient").textContent = "Your response goes to " + message.author + " and is saved in this group.";
    const fields = $("group-input-fields");
    fields.replaceChildren();
    for (const [index, field] of message.form.fields.entries()) {
      const label = document.createElement("label");
      label.textContent = field.label + (field.required ? "" : " (optional)");
      const input = document.createElement(field.choices ? "select" : "input");
      input.id = "group-answer-field-" + index;
      input.name = field.key;
      label.htmlFor = input.id;
      input.required = field.required;
      if (field.choices) {
        input.append(new Option(field.required ? "Choose an option" : "Leave blank", ""),
          ...field.choices.map((choice) => new Option(choice, choice)));
      } else {
        input.type = "text";
        input.maxLength = 300;
        input.autocomplete = "off";
      }
      fields.append(label, input);
    }
    show("group-input-error", "");
    $("group-input-dialog").showModal();
  }

  function renderValues(text) {
    const prefix = "Form response: ";
    if (!text.startsWith(prefix)) return null;
    try {
      const entries = Object.entries(JSON.parse(text.slice(prefix.length)));
      if (!entries.length) {
        const empty = document.createElement("p");
        empty.textContent = "Submitted without optional answers.";
        return empty;
      }
      const list = document.createElement("dl");
      list.className = "group-form-values";
      for (const [key, value] of entries) {
        const term = document.createElement("dt");
        term.textContent = key.replaceAll("_", " ");
        const answer = document.createElement("dd");
        answer.textContent = value;
        list.append(term, answer);
      }
      return list;
    } catch {
      return null;
    }
  }

  function renderFiles(view, disabled) {
    const attach = $("group-attach");
    const list = $("group-draft-files");
    attach.hidden = !app.attachments;
    attach.disabled = disabled || view.files.length >= 4;
    const warning = view.missing.length ? "Select these files again: " + view.missing.join(", ") + "." : "";
    if ($("group-missing-files-label").textContent !== warning) show("group-missing-files-label", warning);
    $("group-missing-files").hidden = !warning;
    list.hidden = !view.files.length;
    if (view.filesKey?.files === view.files && view.filesKey?.sending === state.sending.has(view.id)) return;
    view.filesKey = {files: view.files, sending: state.sending.has(view.id)};
    list.replaceChildren(...view.files.map((file, index) => {
      const row = document.createElement("li");
      row.className = "draft-file";
      const label = document.createElement("span");
      label.textContent = file.name;
      const remove = document.createElement("button");
      remove.type = "button";
      remove.textContent = "Remove";
      remove.setAttribute("aria-label", "Remove " + file.name);
      remove.disabled = state.sending.has(view.id);
      remove.addEventListener("click", () => {
        view.files = view.files.filter((_, fileIndex) => fileIndex !== index);
        stashDraft();
        show("group-error", "");
        render();
        if (!$("group-attach").hidden && !$("group-attach").disabled) $("group-attach").focus();
      });
      row.append(label, remove);
      return row;
    }));
  }

  function messageRow(message, group) {
    const article = document.createElement("article");
    article.dataset.messageId = message.id;
    article.className = message.author ? "task-item group-reply" : "task-item";
    const meta = document.createElement("div");
    meta.className = "task-meta";
    const who = document.createElement("strong");
    who.textContent = message.author ?? "You";
    const time = document.createElement("time");
    time.dateTime = new Date(message.at_ms).toISOString();
    time.textContent = displayDate(message.at_ms);
    meta.append(who, time);
    const text = document.createElement("p");
    text.textContent = message.text;
    article.append(meta);
    if (message.reply_to) {
      const quote = document.createElement("blockquote");
      quote.className = "group-quote";
      const body = document.createElement("div");
      const label = document.createElement("strong");
      label.textContent = (message.reply_to.is_form ? "Form response to " : message.reply_to.is_question ? "Answer to " : "Reply to ") + message.reply_to.author;
      const excerpt = document.createElement("p");
      excerpt.textContent = message.reply_to.text || "Shared files";
      body.append(label, excerpt);
      quote.append(body);
      article.append(quote);
    }
    if (message.is_question) {
      const kind = document.createElement("small");
      kind.className = "group-answer-state";
      const noun = message.form ? "Response" : "Answer";
      const answerStatus = ({pending:"sending…", sent:"sent", start_not_observed:"sent · start not observed",
        not_sent:"not sent", unconfirmed:"delivery unconfirmed"})[message.answer_state];
      kind.textContent = answerStatus ? noun + " " + answerStatus : message.form ? "Form" : "Question";
      article.append(kind);
    }
    if (message.text.trim()) article.append((message.reply_to?.is_form ? renderValues(message.text) : null)
      || (message.rendered ? window.replyMarkup.render(message.rendered, message.text) : text));
    if (message.handoff) {
      const button = document.createElement("button");
      button.type = "button";
      button.dataset.groupHandoff = `/api/groups/${group}/handoffs/${message.id}`;
      window.workspaceGroupHandoffs.label(button, message.handoff);
      button.addEventListener("click", () => void window.workspaceGroupHandoffs.open(group, message.id));
      article.append(button);
      return article;
    }
    if (message.files?.length) {
      const files = document.createElement("ul");
      files.className = "group-files";
      files.setAttribute("aria-label", "Message attachments");
      for (const file of message.files) {
        const item = document.createElement("li");
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = "Download " + file.name;
        button.addEventListener("click", async () => {
          button.disabled = true;
          try {
            await downloadBlob(`/api/groups/${group}/files/${file.id}`, file.name, () => state.view?.id === group);
          } catch {
            if (state.view?.id === group) show("notice", "The group attachment couldn’t be downloaded. Try again.");
          } finally {
            button.disabled = false;
          }
        });
        const preview = document.createElement("button");
        preview.type = "button";
        preview.textContent = "Preview";
        preview.setAttribute("aria-label", "Preview " + file.name);
        preview.addEventListener("click", () => {
          if (!$("library").open) $("library").showModal();
          void showFile(file.id, group);
        });
        item.append(button, preview);
        files.append(item);
      }
      article.append(files);
    }
    if (message.deliveries.length) {
      const list = document.createElement("ul");
      list.className = "receipts";
      list.setAttribute("aria-label", "Delivery by agent");
      for (const receipt of message.deliveries) {
        const item = document.createElement("li");
        item.textContent = `${receipt.name}: ${deliveryLabel[receipt.state] ?? receipt.state}${receipt.detail ? " — " + receipt.detail : ""}`;
        list.append(item);
      }
      article.append(list);
    }
    if (message.target && (!message.is_question || !message.answer_state || message.answer_state === "not_sent")) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "group-direct-reply";
      button.dataset.directReply = message.id;
      button.textContent = message.form ? "Fill out form" : message.is_question ? "Answer" : "Reply";
      button.disabled = !canReply(message);
      button.addEventListener("click", () => {
        if (!canReply(message)) return;
        if (message.form) { openForm(message); return; }
        state.view.reply = message;
        stashDraft();
        show("group-error", "");
        render();
        $("group-task").focus();
      });
      article.append(button);
    }
    if (message.author && !message.is_question && message.text.trim()) {
      const copy = document.createElement("button");
      copy.type = "button";
      copy.className = "group-direct-reply";
      copy.textContent = "Save as page";
      copy.addEventListener("click", () => window.workspacePages.fromReply(message.text));
      article.append(copy);
      const source = state.groups.find((item) => item.id === group);
      if (source && message.target) {
        article.append(handoffButton(message.text, message.author + " in " + source.name, source.core, idOf(message.target)));
      }
    }
    article.append(window.messageReactions.button(message, `/api/groups/${group}/messages`));
    return article;
  }

  function showDrafts(view, drafts) {
    const zone = $("group-live-drafts");
    const key = JSON.stringify(drafts);
    if (view.draftKey === key) return;
    view.draftKey = key;
    zone.hidden = !drafts.length;
    zone.replaceChildren(...drafts.map((draft) => {
      const article = document.createElement("article");
      article.className = "task-item live-reply";
      const meta = document.createElement("div");
      meta.className = "task-meta";
      const who = document.createElement("strong");
      who.textContent = draft.author;
      const label = document.createElement("small");
      label.className = "subtle";
      label.textContent = draft.delivery_id ? "Live reply preview" : "Progress update";
      if (draft.task_id) article.dataset.taskId = String(draft.task_id);
      meta.append(who, label);
      const task = document.createElement("p");
      task.className = "subtle";
      task.textContent = draft.task.trim().replace(/\s+/g, " ");
      const text = document.createElement("p");
      text.textContent = draft.text;
      article.append(meta, task, text);
      return article;
    }));
  }

  async function read(older = false) {
    const view = state.view;
    if (!view || (older && (!view.before || view.older))) return;
    if (older) view.older = true;
    const seq = older ? null : ++view.sequence;
    const key = view.id;
    const anchor = view.anchor;
    const cursor = older ? view.before : anchor ? anchor + 1 : null;
    try {
      const page = await api(`/api/groups/${key}/messages${cursor ? "?before=" + cursor : ""}`);
      if (view !== state.view || anchor !== view.anchor || (!older && seq !== view.sequence)) return;
      const list = $("group-panel");
      const prior = list.scrollHeight;
      const bottom = view.first || prior - list.scrollTop - list.clientHeight < 24;
      if (older || view.paged) {
        const map = new Map(view.entries.map((entry) => [entry.id, entry]));
        for (const entry of page.items) map.set(entry.id, entry);
        view.entries = Array.from(map.values()).sort((a,b) => a.id - b.id);
      } else view.entries = page.items;
      if (older || !view.paged) view.before = page.before;
      if (older) view.paged = true;
      view.first = false;
      const signature = JSON.stringify(view.entries);
      if (signature !== view.signature) {
        window.messageReactions.replaceRows($("group-messages"), view.entries.map((message) => messageRow(message, key)));
        view.signature = signature;
      }
      if (!older) showDrafts(view, anchor ? [] : [...(page.drafts || []), ...(page.live_drafts || [])]);
      $("group-older").hidden = !view.before;
      $("group-latest").hidden = !anchor;
      show("group-notice", view.entries.length ? "" : "Choose recipients and give the group a task.");
      if (older) list.scrollTop += list.scrollHeight - prior;
      else if (anchor && view.jump) {
        view.jump = false;
        focusMessage($("group-messages"), anchor);
      }
      else if (bottom) list.scrollTop = list.scrollHeight;
      if (!older && !anchor && bottom) {
        const latest = page.items.findLast((entry) => entry.author && !entry.is_question);
        window.workspaceActivity?.see({kind:"group",group:key}, latest?.id);
      }
    } catch (error) {
      if (view === state.view) show("group-notice", error.message);
    } finally {
      if (view === state.view && older) view.older = false;
    }
  }

  async function refresh() {
    if (state.fetching) return;
    state.fetching = true;
    const revision = state.revision;
    try {
      const groups = await api("/api/groups");
      if (revision !== state.revision) return;
      state.groups = groups;
      renderRoster($("search").value.trim().toLowerCase());
      render();
      if (state.view) await read();
    } catch (error) {
      if (state.view) show("group-notice", error.message);
    } finally {
      state.fetching = false;
    }
  }

  function dialog(edit = false) {
    const group = opened();
    if (edit ? !group : $("new-group").disabled) return;
    const running = !edit || connected(group) ? qualified() : [];
    const existing = new Set(edit ? group.members.map(idOf) : []);
    const members = new Map(edit ? group.members.map((member) => [idOf(member), member]) : []);
    for (const agent of running) members.set(idOf(agent), { ...agent, name: title(agent) });
    const runningKeys = new Set(running.map(idOf));
    state.editor = { group: edit ? group : null, members };
    $("group-heading").textContent = edit ? "Edit group" : "New group";
    $("group-save").textContent = edit ? "Save group" : "Create group";
    $("group-history-help").hidden = !edit;
    $("group-name").value = edit ? group.name : "";
    $("group-options").replaceChildren(...Array.from(members, ([key, agent]) => option(
      agent, "member", existing.has(key), false, null, agent.name + (runningKeys.has(key) ? "" : " (unavailable)")
    )));
    show("group-form-error", "");
    $("group-dialog").showModal();
  }

  $("new-group").addEventListener("click", () => dialog());
  $("group-edit").addEventListener("click", () => dialog(true));
  $("group-cancel").addEventListener("click", () => { if (!state.changing) $("group-dialog").close(); });
  $("group-dialog").addEventListener("cancel", (event) => { if (state.changing) event.preventDefault(); });
  $("group-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (state.changing || !state.editor) return;
    const {group, members} = state.editor;
    const body = { name: $("group-name").value,
      members: Array.from($("group-options").querySelectorAll("input:checked"), (item) => target(members.get(item.value))) };
    if (body.members.length < 2 || body.members.length > 6) {
      show("group-form-error", "Choose two to six different agents.");
      return;
    }
    if (group) body.revision = group.revision;
    state.changing = true;
    $("group-save").disabled = true;
    show("group-form-error", "");
    try {
      const saved = await api(group ? `/api/groups/${group.id}` : "/api/groups", body);
      ++state.revision;
      state.groups = [saved, ...state.groups.filter((item) => item.id !== saved.id)];
      $("group-dialog").close();
      open(saved.id);
    } catch (error) {
      show("group-form-error", error.message);
      if (error.status === 409) void refresh();
    } finally {
      state.changing = false;
      $("group-save").disabled = false;
    }
  });
  $("group-older").addEventListener("click", () => read(true));
  $("group-latest").addEventListener("click", () => {
    if (state.view) void jumpTo(state.view, null);
  });
  $("group-input-close").addEventListener("click", () => { if (!formSending) $("group-input-dialog").close(); });
  $("group-input-dialog").addEventListener("close", () => { formRequest = null; });
  $("group-input-dialog").addEventListener("cancel", (event) => { if (formSending) event.preventDefault(); });
  $("group-input-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!formRequest || formSending) return;
    const group = opened();
    const { message } = formRequest;
    const current = state.view?.entries.find((entry) => entry.id === message.id) || message;
    if (group?.id !== formRequest.group || !canReply(current)) {
      show("group-input-error", "The original agent is unavailable or the form already has a response.");
      return;
    }
    const values = Object.fromEntries(new FormData(event.target));
    if (Object.values(values).some((value) => new TextEncoder().encode(value).length > 300)) {
      show("group-input-error", "Use up to 300 bytes in each text field.");
      return;
    }
    formSending = true;
    $("group-input-fields").disabled = $("group-input-submit").disabled = true;
    $("group-input-submit").textContent = "Sending…";
    show("group-input-error", "");
    try {
      await api(`/api/groups/${group.id}/messages`, {text:"", recipients:[message.target],
        revision:group.revision, reply_to:message.id, form_values:values});
      $("group-input-dialog").close();
      await read();
    } catch (error) {
      show("group-input-error", error.message);
      if (error.status === 409) void refresh();
    } finally {
      formSending = false;
      $("group-input-fields").disabled = $("group-input-submit").disabled = false;
      $("group-input-submit").textContent = "Send response";
    }
  });
  $("group-cancel-reply").addEventListener("click", () => {
    if (!state.view || state.sending.has(state.view.id)) return;
    state.view.reply = null;
    stashDraft();
    show("group-error", "");
    render();
    $("group-task").focus();
  });
  $("group-attach").addEventListener("click", () => $("group-file-picker").click());
  $("group-transcript").addEventListener("click", () => {
    const view = state.view;
    if (!view) return;
    void downloadTranscript($("group-transcript"), `/api/groups/${view.id}/transcript`, "notice",
      () => state.view === view && app.authorized);
  });
  $("group-ignore-missing").addEventListener("click", () => {
    if (!state.view || state.sending.has(state.view.id)) return;
    state.view.missing = [];
    stashDraft();
    render();
    if (!$("group-task").disabled) $("group-task").focus();
  });
  $("group-file-picker").addEventListener("change", (event) => {
    const files = [...event.target.files];
    event.target.value = "";
    addFiles(files);
  });
  bindComposerFiles($("group-compose"), $("group-task"), canAttachFiles, addFiles,
    (message) => show("group-error", message));

  function canAttachFiles() {
    return Boolean(state.view && connected(opened()) && app.attachments && !state.sending.has(state.view.id));
  }

  function dictationDraft() {
    if (!app.authorized || !state.view || !connected(opened())) return null;
    const field = $("group-task");
    return {key:state.view.slot, field, canEdit:!field.disabled, limit:8 * 1024};
  }

  function voiceDraft() {
    const view = state.view;
    if (!app.authorized || !connected(opened()) || !app.attachments || !view) return null;
    return {key:view.slot, canAdd:canAttachFiles(), bytes:view.files.length >= 4 ? 0
      : fileLimit - view.files.reduce((sum, file) => sum + file.size, 0)};
  }

  function addVoiceMemo(key, file) {
    const target = voiceDraft();
    if (!target?.canAdd || key !== target.key || file.size > target.bytes) return false;
    return addFiles([file]);
  }

  function addFiles(files) {
    const view = state.view;
    if (!canAttachFiles() || !files.length) return false;
    const draft = [...view.files, ...files];
    if (draft.length > 4) {
      show("group-error", "Attach up to four files per group message.");
      return false;
    }
    if (draft.reduce((total, file) => total + file.size, 0) > fileLimit) {
      show("group-error", "Group attachments must total 8 MiB or less.");
      return false;
    }
    view.files = draft;
    const missing = [...view.missing];
    for (const file of files) {
      const index = missing.indexOf(file.name);
      if (index >= 0) missing.splice(index, 1);
    }
    view.missing = missing;
    stashDraft();
    show("group-error", "");
    render();
    return true;
  }
  $("group-task").addEventListener("input", () => {
    if (state.view) {
      state.view.dismissed = null;
      stashDraft();
    }
    render();
  });
  $("group-task").addEventListener("click", render);
  $("group-task").addEventListener("keyup", (event) => {
    if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) render();
  });
  $("group-compose").addEventListener("focusout", (event) => {
    if (!$("group-mentions").contains(event.relatedTarget) && event.relatedTarget !== $("group-task")) {
      $("group-mentions").hidden = true;
    }
  });
  $("group-compose").addEventListener("keydown", (event) => {
    if ($("group-mentions").hidden) return;
    if (event.key === "ArrowDown" && event.target === $("group-task")) {
      event.preventDefault();
      $("group-mentions").querySelector("button")?.focus();
    } else if (event.key === "Escape") {
      event.preventDefault();
      const task = $("group-task");
      state.view.dismissed = JSON.stringify([task.value, task.selectionStart]);
      task.focus();
      render();
    }
  });
  $("group-compose").addEventListener("submit", async (event) => {
    event.preventDefault();
    const view = state.view;
    const group = opened();
    if (!view || !group || $("group-send").disabled) return;
    const text = $("group-task").value;
    const { selected, unavailable, closed } = routing(view, choicesFor(group), text);
    if (!selected.length || unavailable.length || closed) return;
    const recipients = selected.map(({member}) => target(member));
    state.sending.add(group.id);
    show("group-error", "");
    render();
    try {
      const message = {text, recipients, revision: group.revision, reply_to: view.reply?.id};
      const path = `/api/groups/${group.id}/messages`;
      if (view.files.length) {
        const form = new FormData();
        form.append("message", JSON.stringify(message));
        for (const file of view.files) form.append("file", file);
        await api(path + "/with-files", form);
      } else {
        await api(path, message);
      }
      state.drafts.delete(view.slot);
      saveTabDraft("group", view.slot, null);
      if (state.view?.id === group.id) {
        state.view.files = [];
        state.view.missing = [];
        state.view.reply = null;
        $("group-task").value = "";
        await read();
      }
    } catch (error) {
      if (state.view?.id === group.id) show("group-error", error.message);
      else show("notice", error.message);
      if (error.status === 409) void refresh();
    } finally {
      state.sending.delete(group.id);
      if (state.view?.id === group.id) {
        render();
        if (!$("group-task").disabled) $("group-task").focus();
      }
    }
  });

  document.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.key.toLowerCase() === "n"
      && !document.querySelector("dialog[open]") && !$("new-group").disabled) {
      event.preventDefault();
      dialog();
    }
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter" && event.target === $("group-task")
      && !$("group-send").disabled) {
      event.preventDefault();
      $("group-compose").requestSubmit();
    }
  });

  async function openById(id) {
    if (!state.groups.some((group) => group.id === id)) {
      const group = await api(`/api/groups/${id}`);
      ++state.revision;
      state.groups = [group, ...state.groups.filter((item) => item.id !== id)];
    }
    open(id);
  }
  async function openRequest(group, id) {
    await openById(group);
    const view = state.view;
    const page = await api("/api/groups/" + group + "/messages?before=" + (id + 1));
    if (state.view !== view) return;
    const message = page.items.find((item) => item.id === id && item.is_question);
    if (!canReply(message)) {
      show("notice", "This request cannot be answered right now. Check the conversation for its latest status.");
      return;
    }
    if (message.form) {
      openForm(message);
    } else {
      view.reply = message;
      stashDraft();
      show("group-error", "");
      render();
      $("group-task").focus();
    }
  }
  function jumpTo(view, id) {
    Object.assign(view, {anchor:id, jump:Boolean(id), first:true, entries:[], before:null, paged:false, older:false, signature:null});
    $("group-messages").replaceChildren();
    showDrafts(view, []);
    $("group-latest").hidden = !id;
    return read();
  }
  async function openMessage(group, id) {
    await openById(group);
    if (state.view?.id === group) await jumpTo(state.view, id);
  }
  function clearDrafts() {
    state.view = null;
    state.drafts.clear();
    state.groups = [];
    state.rosterKey = null;
    ++state.revision;
    renderRoster("");
  }
  function updateHandoff(group, message, status) {
    const view = state.view;
    if (view?.id !== group) return;
    const entry = view.entries.find((row) => row.id === message);
    if (entry) entry.handoff = status;
    void read();
  }

  window.groupWorkspace = { active: () => Boolean(state.view), leave, clearDrafts, openById, openRequest, openMessage, render, refresh, renderRoster, voiceDraft, addVoiceMemo, dictationDraft, updateHandoff,
    attachmentDraft: voiceDraft, addDraftAttachment: addVoiceMemo };
})();
