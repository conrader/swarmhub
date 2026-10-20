# App Store review notes: bundle-delivered views (draft, P7c)

Draft for the next iOS submission's review notes. Submission is Konrad's step; nothing here has been sent to Apple. Source rules: `CORE-PLAN.md` §5.3 (guidelines 2.5.2 and 2.3.1) and §5.2 (what ships without a build).

## Before submitting

- [ ] **Re-read guideline 2.5.2** in Apple's current App Review Guidelines. §5.3 records the wording as known in mid-2026 ([A]); compare it against the text on the day you submit.
- [ ] Re-read 2.3.1 and check the list below still matches what the review build and its demo setup can show.
- [ ] Confirm the review build ships with no bundle installed, or with exactly the bundle the notes describe.

## What to tell the reviewer

SwarmHub can show a small set of screens from signed **view documents**: JSON data that describes a layout from a fixed catalogue of native SwiftUI components compiled into the app. The app does not download or run code. There is no JavaScript, WebAssembly, Lua, `JSContext`, web view, dynamic library or bytecode loading. Documents have no expressions or loops. A document can only:

- show text (plain, or Markdown limited to bold, italic and code, with every link removed), badges, key/value rows, lists, cards, progress bars and diff previews;
- show a form whose fields are text, multi-line text, choice, toggle, date, schedule or a file name;
- offer buttons and step-by-step flows that call actions already compiled into the app: dismiss, refresh, copy text, open a web link, open a fixed app screen, and run, pause, resume, create or save a routine.

Links open only for hosts compiled into the app (the list is empty in this build) and only after the user confirms. No document can reach approvals, keys, secrets or sign-in screens, and none can approve or decide anything. Removing the bundle, or turning a view off with the kill switch, shows the app's compiled screen.

## Bundle-delivered capabilities in this build (2.3.1)

| Capability | Where it appears on iOS | What the reviewer sees in the review build |
| --- | --- | --- |
| Routine result card (`routine_result_card`) | Nowhere yet. The iOS app has no routine screens, so no screen shows this view. | Nothing. A bundle cannot add it. |
| Routine create form (`routine_create_form`) | Nowhere yet (as above). On iOS, routine create and save are not offered, so the form's submit would stay disabled. | Nothing. |
| Routine edit form (`routine_form`) | Nowhere yet (as above). | Nothing. |
| "Update required" screen | Only where a view above is shown, for a `critical` document this build cannot read. | Nothing. |

**This build exposes no bundle-delivered capability on iOS.** The renderer is compiled in so that a later build with native routine screens can use it. When that build ships, list each view it mounts here, say what it adds over the compiled screen, and make sure the review/demo setup shows the same document a user would get. Do not turn on after review anything the reviewer could not see (for example real outbound Draft Send).

## Still to settle before the first submission that mounts a view

- Which iOS screens mount the routine views, and whether iOS gets the routine create, save, run and pause paths (a new compiled feature and Hermes API use, so it needs a build and review in any case).
- Whether any `open_url` host is allowed (adding one is an app build).
- The demo/sample mode bundle: the reviewer should see the same documents as users.
