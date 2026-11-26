(() => {
  "use strict";
  const settings = $("ci-push-settings"), button = $("ci-push-toggle"), status = $("ci-push-status");
  let registration, key, subscription, enabled = false, working = false;
  let pendingReview = location.hash === "#ci-review";

  function openPendingReview() {
    if (!pendingReview || !app.authorized || $("attention-open").disabled) return;
    pendingReview = false;
    if (location.hash === "#ci-review") history.replaceState(history.state, "", location.pathname + location.search);
    if (!$("attention-dialog").open) $("attention-open").click();
  }

  navigator.serviceWorker?.addEventListener("message", (event) => {
    if (event.source?.scriptURL !== new URL("/workspace-sw.js", location.origin).href || event.data !== "ci-review") return;
    pendingReview = true;
    openPendingReview();
  });
  window.ciPush = {openPendingReview};
  openPendingReview();

  function show(message, disabled) {
    button.textContent = enabled ? "Turn off CI alerts" : "Enable CI alerts";
    button.disabled = disabled;
    status.textContent = message;
  }

  async function load() {
    if (!settings.open || working) return;
    if (!isSecureContext || !navigator.serviceWorker || !window.PushManager || !window.Notification) {
      show("On iPhone, add this workspace to the Home Screen from Safari and open it there. Use an HTTPS workspace address.", true);
      return;
    }
    working = true;
    show("Checking this device…", true);
    try {
      registration = await navigator.serviceWorker.getRegistration("/");
      if (!registration?.active) throw new Error("The workspace is starting. Reopen this setting in a moment.");
      const response = await api("/api/ci-push/key");
      key = Uint8Array.from(atob(response.key.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));
      subscription = await registration.pushManager.getSubscription();
      enabled = subscription && (await api("/api/ci-push/device", {endpoint:subscription.endpoint})).enabled;
      if (Notification.permission === "denied") show("Notifications are blocked in this device’s settings.", !enabled);
      else show(enabled ? "CI alerts are on." : "CI alerts are off.", false);
    } catch (e) { show(e.message, true); }
    finally { working = false; }
  }
  settings.addEventListener("toggle", load);
  button.addEventListener("click", async () => {
    if (!app.authorized || working || !registration || !key) return;
    working = true;
    show(enabled ? "Turning alerts off…" : "Enabling alerts…", true);
    try {
      if (enabled) {
        await api("/api/ci-push/device", {endpoint:subscription.endpoint, enabled:false});
        enabled = false;
        await subscription.unsubscribe();
        subscription = null;
      } else {
        // Safari requires subscribe to run directly from the user gesture.
        subscription = await registration.pushManager.subscribe({userVisibleOnly:true, applicationServerKey:key});
        enabled = (await api("/api/ci-push/device", {endpoint:subscription.endpoint, enabled:true})).enabled;
      }
      show(enabled ? "CI alerts are on." : "CI alerts are off.", false);
    } catch (e) {
      const denied = Notification.permission === "denied";
      show(denied ? "Notifications are blocked in this device’s settings." : e.message, denied && !enabled);
    } finally { working = false; }
  });
})();
