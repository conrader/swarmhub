# Avatar animation scenarios

Use [BotAvatars from Libraries.dev](https://libraries.dev/bots), through the pinned MIT BotAvatarsKit SwiftUI port,
with **flat shading**, rim 0, brightness 1 and saturation 1. All animation comes from its original simulation engine.
The app selects states, triggers the existing tap gesture and supplies a gaze target; it does not replace poses or
implement its own breathing, blink, jump or squash curves.

The 2026-10-14 revision replaces P15's hover-only sidebar rule. Marks animate whenever the app is active and a main
window is visible. Each bot's stable seed varies the library's timings.

| Scenario | Trigger | Existing library animation |
| --- | --- | --- |
| Idle | A visible list mark without work or an approval | `default`: breathing, blinks, occasional winks, eye darts, head wander, body jelly, and automatic jump-and-turn gestures. |
| Focused | The open bot's header, Overview, welcome or import preview | The same `default` animation, aimed toward the nearby conversation text. |
| Greeting | Pointer enters a bot or group row | `default` plus the built-in tap event (`sim.poke()`): crouch, hop, full turn, stretch, landing squash and recovery. |
| Working | That bot is answering | `working`: repeated hops, a spin every third hop, alternating lean, squash and stretch, and happy eye arcs. |
| Waiting | That bot has an approval awaiting a decision | `sleeping`: a slump, shut lids, slow deep breathing and occasional sleepy nods. Group marks react only to approvals in that group's member session. |
| Completion | A successful, nonempty reply finishes | Return to `default` and trigger the built-in tap hop-and-turn once. Cancelled, failed and empty replies do not trigger it. |

Priority is Reduce Motion / Off / still context, then waiting, working, completion, greeting, idle. The library blends
state changes and finishes the last working hop before settling. Completion events expire after two seconds and are
transient presentation state; reopening an old conversation does not replay its historical replies.

## Facing the content

- Sidebar bots and group clusters look right toward the conversation.
- The chat header looks right toward the name and text.
- Overview and the right panel's member avatars look left toward the conversation.
- The centred welcome avatar looks down toward its greeting text.
- Message author marks face their adjacent text and remain still; picker marks face forward.

The target uses the library's smoothed pointer-following controls, independently of the real pointer. Glances and
head movement stay oriented toward the content between gestures. The library's full turns are preserved, then the
avatar settles toward the text again. Static marks retain the same inward target when motion is off.

## Motion preferences and lifecycle

**By context** uses the library's original playback speed and jump defaults. **Calm everywhere** uses its speed
control at 0.55×, disables automatic idle jumps, and suppresses greeting and completion tap events. Breathing, blinks,
working and waiting retain their native animation. **Off** and macOS **Reduce Motion** draw a static mark; Reduce
Motion retains the existing working-status dot.

All scenarios pause when the app is inactive, minimised or occluded. The live views give way to static views and the
shared display link stops when its last subscriber leaves. Motion resumes automatically on return; expired
completion gestures do not queue up in the background.

The original `BotAvatarEngine.swift` and `BotAvatarDraw.swift` stay byte-for-byte unchanged from the vendored pin.
The smoke report records each mark's facing, scenario, native `kit_state` and Calm setting; checks working frames
advance and return to idle; and separately checks that Off stops the clock.
