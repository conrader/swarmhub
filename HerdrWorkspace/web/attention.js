(() => {
  "use strict";
  const dialog = $("attention-dialog");
  const empty = () => ({ approvals: [], requests: [], webhook_reviews: [], completions: [], more: false });
  let queue = empty();
  let polling, ready = false, signature;
  const terminalKey = (core, address, created) => JSON.stringify([core, address, created]);

  function entries() {
    const approvals = queue.approvals.map((item) => ({
      key: item.id,
      title: item.agent + " · " + item.tool, summary: item.provider + " · Approval requested",
      open: () => window.approvalInbox.open(item.id),
    }));
    const covered = new Set(queue.approvals.filter((item) => item.terminal).map(({terminal}) => terminalKey(...terminal)));
    const terminals = new Map((app.online ? app.agents.filter(live) : []).map((item) =>
      [terminalKey(app.core, item.address, item.created_ms), item]));
    const blocked = [...terminals].filter(([key, agent]) =>
      agent.status?.state === "blocked" && !(agent.status.kind === "permission" && covered.has(key)))
      .map(([key, agent]) => ({
        key,
        title: window.agentProfiles.profileFor(idOf(agent), app.core)?.name || title(agent),
        summary: ({permission: "Permission needed", question: "Question in the terminal", auth: "Sign-in needed"})[agent.status.kind] || "Waiting for you in the terminal",
        open: () => {
          select(idOf(agent));
          if (!$("takeover").disabled && !$("takeover").hidden) $("takeover").click();
          else $("conversation").focus();
        },
      }));
    const requests = queue.requests.map((item) => ({
      key: item.id,
      title: item.text, summary: [item.form ? "Form" : "Question", item.agent, item.group_name,
        terminals.has(terminalKey(item.core, item.address, item.created_ms)) ? null : "Agent unavailable"].filter(Boolean).join(" · "),
      open: () => window.groupWorkspace.openRequest(item.group, item.id),
    }));
    const reviews = (queue.webhook_reviews || []).map((item) => ({
      key: item.id, title: item.name,
      summary: ["Event #" + item.id + " awaiting review", item.agent, displayDate(item.at_ms)].join(" · "),
      open: () => window.workspaceRoutines.openReview(item.routine, item.id),
    }));
    const completions = (queue.completions || []).map((item) => ({
      key: item.id, title: "Completion " + item.id,
      summary: [item.owner_bot_id, ({
        pending: "Pending delivery", offered: "Awaiting acknowledgment", uncertain: "Delivery unconfirmed",
      })[item.state], item.blocker].filter(Boolean).join(" · "),
    }));
    return [["Approvals", approvals], ["Terminals", blocked], ["Group questions and forms", requests],
      ["Webhook reviews", reviews], ["Job completions", completions]];
  }

  function render() {
    const sections = entries().filter(([, items]) => items.length);
    const count = sections.reduce((total, [, rows]) => total + rows.length, 0);
    const badge = $("attention-count");
    badge.hidden = !count;
    const number = String(count) + (queue.more ? "+" : "");
    if (badge.textContent !== number) badge.textContent = number;
    if (!dialog.open) return;
    show("attention-status", !ready ? "Checking for requests…" : count ? queue.more ? "Showing the latest requests." : "" : "Nothing needs your attention.");
    const key = JSON.stringify(sections);
    if (key === signature) return;
    signature = key;
    $("attention-list").replaceChildren(...sections.map(([label, items]) => {
      const section = document.createElement("section");
      const heading = document.createElement("h3");
      heading.textContent = label;
      const list = document.createElement("ul");
      list.className = "library-items";
      for (const item of items) {
        const row = document.createElement("li");
        const content = document.createElement(item.open ? "button" : "div");
        const title = document.createElement("strong");
        const summary = document.createElement("small");
        title.textContent = item.title;
        summary.textContent = item.summary;
        content.append(title, summary);
        if (item.open) {
          content.type = "button";
          content.addEventListener("click", async () => {
            dialog.close();
            try { await item.open(); }
            catch (error) { show("notice", error.message); }
          });
        }
        row.append(content);
        list.append(row);
      }
      section.append(heading, list);
      return section;
    }));
  }

  async function load() {
    try {
      const result = await api("/api/attention");
      if (!app.authorized) return;
      queue = result;
      ready = true;
      render();
    } catch (error) {
      if (dialog.open) show("attention-status", error.message);
    } finally {
      polling = null;
    }
  }
  function refresh() {
    if (!app.authorized) {
      queue = empty();
      ready = false;
      render();
      return;
    }
    if (!document.hidden || dialog.open) return polling ||= load();
  }
  $("attention-open").addEventListener("click", () => {
    dialog.showModal();
    render();
    void refresh();
  });
  $("attention-close").addEventListener("click", () => dialog.close());
  window.workspaceAttention = { refresh };
})();
