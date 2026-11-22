# Trackball Scroll

A macOS app that lets a trackball user scroll by holding a mouse button and rolling the ball, with the smoothness of a trackpad.

## Language

**Ball Scrolling**:
Scrolling content by rolling the trackball while a mouse button is held, instead of moving the pointer.
_Avoid_: Drag scrolling, scroll mode, button scrolling

**Trigger Button**:
The mouse button the user holds to start Ball Scrolling. Chosen by the user from the mouse's buttons; never a keyboard key.
_Avoid_: Scroll button, hotkey, modifier

**Dead Zone**:
The amount of ball movement, after the button is pressed, that is ignored before Ball Scrolling starts. A press released inside the Dead Zone is an ordinary click; zero means any movement scrolls.
_Avoid_: Threshold, tolerance, slop

**Axis Lock**:
Restricting one Ball Scrolling gesture to the axis the ball first moved along, vertical or horizontal, until the Trigger Button is released. User-switchable; when off, both axes scroll at once.
_Avoid_: Direction lock, snap, straight scrolling

**Excluded App**:
An app the user has listed in which Ball Scrolling is switched off while that app is frontmost, so the Trigger Button behaves as an ordinary button there.
_Avoid_: Blacklist, ignored app, exception

**Pause**:
The user manually switching Ball Scrolling off everywhere until they switch it back on.
_Avoid_: Disable, suspend, mute

**Momentum**:
The glide that continues a scroll after the user lets go while the ball is still moving, decaying to a stop. A user-switchable part of Ball Scrolling.
_Avoid_: Inertia, glide, kinetic scrolling
