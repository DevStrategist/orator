# Recording, wake and shortcut behavior

| Behavior | Orator implementation |
| --- | --- |
| Hold to talk; releases before 500 ms wait another 500 ms before discarding | `PushToTalkGesture`, controller session-scoped expiry |
| Second press less than 500 ms after the first locks hands-free | `PushToTalkGesture.press` |
| Third press in that same window discards; a later press finishes | Gesture and controller discard handling |
| Fn, modifier chords, ordinary key combinations, HID Caps Lock, and mouse buttons 3–32 | Shared shortcut policy, event tap, shortcut recorder and saved settings |
| Releases of unrelated modifiers cannot start a shortcut | Modifier keycode and exact flag matching |
| Recover missing releases from physical keyboard state after 250 ms | `Hotkeys.reconcile`; checked by the existing one-second watchdog |
| Five event-tap timeouts within 60 seconds restart keyboard handling; user-input disables and the first 30 seconds after wake are exempt | Existing event-tap policy, with wake state cleared |
| Normalize Caps Lock after 50, 150, 400 and 1,000 ms | HID press/release handling; delayed work expires on pause or binding change |
| Recover system activation by polling, in addition to wake signals | One-second console/login/lock-state sampling and wake/unlock notifications |
| Allow a responsive helper time to recover after wake | Twelve-second capture IPC and worker ping deadlines before restarting an unresponsive service |
| Signal readiness after real microphone audio arrives | Immediate rounded opening popup; Listening and its sound follow usable PCM rather than engine startup |
| Recover same-device format changes | Rebuild the engine, tap and converter with bounded retries; drain old PCM and reject retired graph callbacks |
| Detect a stalled or silent microphone | Repair missing callbacks after five seconds; allow one silent-start reopen after six seconds of exact zeros, without rejecting quiet valid audio |
| Release Bluetooth input between dictations | Discard the stopped Bluetooth engine so a later press negotiates a fresh capture format |

Orator keeps its tap installed but paused while locked. Queued shortcut callbacks
are invalidated on pause, wake, stop and binding changes. A missed sleep signal
or long timer gap fails an old dictation safely; it cannot insert a late result.
An accepted resume resets watchdog timestamps so a fresh dictation survives the
first tick after wake.

Live sleep, lock, device reconnect and Bluetooth timing require hardware testing.
Capture permissions replies confirm its IPC loop, not microphone graph health;
an untagged reply already queued before wake can satisfy this check. The existing
capture startup/audio watchdogs cover recording failures. A model still loading
uses its existing startup watchdog rather than the shorter post-wake deadline;
replacing either service invalidates its old probe.

Regression coverage is in `GestureTests`, `ShortcutPolicyTests`, `HotkeysTests`
and `IntegrationTests`. Run `scripts/test.sh`; build the signed application with
`scripts/build.sh`.

Capture regression coverage also uses real converters with synthetic PCM to
check format replacement, final draining and retired graph/session rejection.
Bluetooth profile transitions require live verification with the affected headset.
