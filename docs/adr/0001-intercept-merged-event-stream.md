# Intercept the merged pointer event stream instead of seizing devices

BallScroll watches and rewrites pointer events with a session-wide event tap, after macOS has already merged every pointing device into one stream. The alternative, used by Karabiner-Elements, is to seize each physical device and re-emit its input through a virtual device, which gives exact per-device control but needs a system driver extension, a root helper and Apple's driver entitlement. We chose the event tap so the app needs only the Accessibility permission and can be built and shared without a paid developer account.

## Consequences

- The app cannot tell which device an event came from, so Ball Scrolling applies to every pointing device in the first version.
- Per-device selection, when added, will match raw per-device reports (read without seizing) to tapped events by timing. That needs the Input Monitoring permission and is ambiguous only when two devices press the same button at the same instant.
- The pointer cannot be truly detached from the ball; it is held in place by moving it back, which is why the pointer-freeze code exists.
