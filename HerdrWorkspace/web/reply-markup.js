(() => {
  "use strict";

  function codeBlock(pre) {
    const wrapper = document.createElement("div");
    wrapper.className = "reply-code";
    const bar = document.createElement("div");
    bar.className = "reply-code-bar";
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Copy code";
    const status = document.createElement("span");
    status.setAttribute("role", "status");
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText((pre.querySelector("code") || pre).textContent);
        status.textContent = "Copied.";
      } catch {
        status.textContent = "Select the code to copy it.";
      }
    });
    pre.tabIndex = 0;
    pre.setAttribute("aria-label", "Code block");
    bar.append(button, status);
    pre.replaceWith(wrapper);
    wrapper.append(bar, pre);
  }

  function render(html, source) {
    const body = document.createElement("div");
    body.className = "reply-body";
    const formatted = document.createElement("div");
    formatted.className = "reply-markdown";
    // Only consume output of the bridge's allowlisted Markdown renderer.
    formatted.innerHTML = html;
    for (const link of formatted.querySelectorAll("a")) {
      link.target = "_blank";
      link.rel = "noopener noreferrer";
    }
    for (const table of formatted.querySelectorAll("table")) {
      const scroll = document.createElement("div");
      scroll.className = "reply-table-scroll";
      scroll.tabIndex = 0;
      scroll.setAttribute("aria-label", "Table");
      table.replaceWith(scroll);
      scroll.append(table);
    }
    for (const pre of formatted.querySelectorAll("pre")) codeBlock(pre);

    const raw = document.createElement("pre");
    raw.className = "reply-markdown-source";
    raw.textContent = source;
    raw.tabIndex = 0;
    raw.setAttribute("aria-label", "Original Markdown");
    raw.hidden = true;
    const toggle = document.createElement("button");
    toggle.type = "button";
    toggle.className = "reply-markdown-toggle";
    toggle.textContent = "Show Markdown";
    toggle.addEventListener("click", () => {
      const showSource = raw.hidden;
      raw.hidden = !showSource;
      formatted.hidden = showSource;
      toggle.textContent = showSource ? "Show formatted reply" : "Show Markdown";
    });
    body.append(formatted, raw, toggle);
    return body;
  }

  window.replyMarkup = {render};
})();
