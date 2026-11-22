# BallScroll

Scroll on macOS by holding a mouse button and rolling your trackball, with the
smoothness of a trackpad.

BallScroll is a small menu bar app. Hold the Trigger Button (the right button
by default), roll the ball, and the content under the pointer scrolls while the
pointer stays put. Press and release without rolling and you get an ordinary
click.

## Why it feels smooth

- **Real scroll gestures.** Apps receive the same began / changed / ended
  phases a trackpad sends, so they treat the scroll as one continuous gesture
  rather than a burst of wheel clicks.
- **Sub-pixel precision.** Fractions of a pixel are carried over, never
  dropped, so slow rolling moves the page slowly instead of stuttering.
- **Frame-synced output.** Scroll events are sent once per display refresh, in
  step with the display the pointer is on.
- **Momentum.** Release the button while the ball is still rolling and the
  content glides to a stop. Optional.

## Settings

| Setting | What it does |
| --- | --- |
| Trigger Button | Right, middle, back or forward button. |
| Speed | Pixels scrolled per ball count. |
| Acceleration | Extra distance for fast rolls. Off keeps it linear. |
| Smoothing | Spreads each ball movement over a few frames. Off is the most direct. |
| Dead Zone | How far the ball may move before a press becomes a scroll. Off means any movement scrolls. |
| Axis Lock | Keeps each scroll on the axis the ball first moved along. |
| Reverse vertical / horizontal | By default content follows the ball; these flip an axis. |
| Momentum, Glide | The glide after release, and how long it lasts. |
| Excluded Apps | Apps in which the Trigger Button behaves normally (games, 3D tools). |

The menu bar icon also has **Pause** and a one-click way to exclude the app in
front.

## Install

Requires macOS 14 or later.

```sh
git clone <this repository>
cd BallScroll
Scripts/build-app.sh
cp -R build/BallScroll.app /Applications/
open /Applications/BallScroll.app
```

Building needs only the Xcode Command Line Tools (`xcode-select --install`),
not Xcode itself.

On first launch macOS asks for **Accessibility** access. BallScroll needs it to
watch the Trigger Button and send scroll events. Switch it on in System
Settings > Privacy & Security > Accessibility and BallScroll starts working
right away.

If you downloaded a prebuilt app instead of building it: the app is not
notarized, so macOS blocks the first launch. Open System Settings > Privacy &
Security and choose **Open Anyway**.

Turn off any other tool that does the same job (a Hammerspoon script, the
gesture button in another mouse utility) before using BallScroll, or the two
will fight over the button.

## Development

```sh
Scripts/test.sh        # unit tests (works without Xcode)
Scripts/build-app.sh   # build/BallScroll.app
build/BallScroll.app/Contents/MacOS/BallScroll --debug
```

`--debug` prints one line per gesture: how many ball reports arrived, how many
frames ran, and how far it scrolled. Useful when tuning the feel.

An ad-hoc signed build loses its Accessibility grant every time it is rebuilt,
because macOS ties the grant to the exact binary. To clear the stale entry:

```sh
tccutil reset Accessibility io.github.marek-hubar.BallScroll
```

Signing with a stable identity (`SIGN_IDENTITY=... Scripts/build-app.sh`) keeps
the grant across rebuilds.

### Layout

- `Sources/BallScrollCore` holds the scroll logic as a pure state machine
  (`GestureMachine`): Dead Zone, Axis Lock, acceleration, smoothing, Momentum.
  It never touches the system, so all of it is unit tested.
- `Sources/BallScroll` is the app: the event tap, pointer freeze, scroll event
  posting, menu bar item and settings window.
- `CONTEXT.md` defines the project's vocabulary; `docs/adr` records decisions.

## Limitations

- Ball Scrolling applies to every pointing device, not only the trackball. See
  `docs/adr/0001-intercept-merged-event-stream.md`.
- While the Trigger Button is the right button, right-button dragging is not
  available outside Excluded Apps, and context menus open on release.
