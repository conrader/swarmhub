// Drive the provider's own selector in a visible, attached session. Unknown layouts
// leave control with the person. Only Claude's session-only binding is automated.
window.chooseChatModel = async function (kind, id, label) {
  const surface = window.chatModelTerminal;
  if (!surface) throw Error("Update the bridge to switch models here.");
  const sleep = () => new Promise(resolve => setTimeout(resolve, 150));
  const norm = s => s.trim().toLowerCase().replace(/\s+/g, " ");
  const names = [id, label].filter(Boolean).map(norm);
  const matches = s => names.some(name => s === name || s === name + " ✓" || s === name + " (current)" || s === name + " (default)");
  const lines = () => surface.lines().map(s => s.trim()).filter(Boolean);
  let initialConfirmations;
  const confirmPattern = /^(?:[⎿•●·]\s*)?(?:set model to|switched (?:the )?model to|model (?:changed|switched) to)\s+/i;
  let last = "", opened = false, selected = false, submitted = false, menuSeen = false, moves = 0;
  for (let tick = 0; tick < 1200; tick++) {
    await sleep();
    if (surface.closed()) throw Error("The terminal detached before the model was confirmed.");
    if (!surface.ready()) continue;
    const screen = lines(), prompt = surface.promptLine(), text = screen.join("\n") + "\n" + prompt;
    const confirmations = screen.filter(s => confirmPattern.test(s));
    if (!initialConfirmations) initialConfirmations = confirmations;
    if (text === last) continue;
    last = text;
    const header = screen.findLastIndex(s => /^(select (a )?model|choose (a )?model)( and.*)?$/i.test(s));
    const menu = header >= 0 ? screen.slice(header + 1) : [];
    const menuOpen = menu.length && menu.slice(-5).some(s => /(?:esc.*cancel|enter.*(?:select|confirm)|session only|set as default)/i.test(s));
    if (menuOpen) {
      menuSeen = true;
      // Codex can ask a second question about effort. Its controls remain interactive.
      if (kind !== "Claude Code" || selected || moves >= 15) continue;
      const row = /^(❯|›|>|→)?\s*(?:\d+[.)]\s*)?(.+)$/;
      const options = menu.map((s, i) => ({ i, m: s.match(row) }));
      const current = options.find(o => o.m?.[1]);
      const targets = options.filter(o => o.m && matches(norm(o.m[2].split(/\s{2,}/)[0])));
      if (!current || targets.length !== 1) continue;
      const target = targets[0];
      if (target.i !== current.i) {
        surface.key(target.i > current.i ? "\x1b[B" : "\x1b[A"); moves++;
      } else if (menu.some(s => /\bs\s*(?:[:·=]|to)?\s*(?:use (?:for )?|for )?(?:this )?session only\b/i.test(s))) {
        surface.key("s"); selected = true;
      }
    } else if (!opened && !menuSeen && /^[❯›>]$/.test(prompt)) {
      // Never append a slash command to a draft or a prompt expecting an answer.
      opened = true;
      surface.key("/model");
    } else if (opened && !submitted && !menuSeen && /^[❯›>]\s*\/model$/.test(prompt)) {
      submitted = true; surface.key("\r");
    } else if (menuSeen && !menuOpen) {
      const confirmation = confirmations.at(-1);
      if (confirmation && confirmations.filter(s => s === confirmation).length > initialConfirmations.filter(s => s === confirmation).length) {
        const reported = norm(confirmation.replace(confirmPattern, "")).replace(/[.!]$/, "");
        if (matches(reported)) return true;
      }
    }
  }
  throw Error("The provider has not confirmed this selection. Check the model in its terminal.");
};
