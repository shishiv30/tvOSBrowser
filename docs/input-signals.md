# How the Browser Receives System Input

tvOS does not give each device its own UI. The system first turns devices into a few event types, and the browser folds those events into one set of logical keys: move the pointer, confirm, cancel, menu, scroll, and history back and forward.

There are two entry points, both on the main thread:

- `UIApplication`'s `sendEvent:` (`UIApplication+BrowserSelectPressForwarding.m`) sees the event first. It swallows presses that must be handled before the page.
- `ViewController`'s `pressesBegan` / `pressesEnded` / `touchesBegan` / `touchesMoved` hands the remaining events to `BrowserRemoteInputController`. Returning YES means the browser handled the event and does not call `super`, so the event never reaches `WKWebView`.

Gamepads have a third path: `GCController` button and stick callbacks. The system often translates the same action into a press as well, so both paths arrive together. The browser uses only one of them.

```
Remote touch surface, mouse-like touches  ->  UIEventTypeTouches  ->  pointer movement
Remote presses, keyboard, presses the system synthesizes from a gamepad  ->  UIEventTypePresses  ->  logical keys
Extended gamepad sticks and buttons  ->  GCController callbacks  ->  pointer, scroll, logical keys, or the Gamepad API in Game Mode
Video on the page  ->  navigator.mediaSession  ->  play/pause treated as the menu
```

## Remote

The Siri Remote and the older Apple TV remote use presses and touches. They do not use `GCController`.

Arrow keys are `UIPressTypeUpArrow` through `UIPressTypeRightArrow`. A press starts moving the pointer; holding it makes the pointer faster. A second quick press up or down scrolls the page instead. When the pointer is at the top edge, Up moves focus to the top bar.

Select is confirm. On release it clicks the element under the pointer. The click is only a click; it does not enter fullscreen.

Menu is cancel. While browsing it goes back, and when there is no history it asks whether to quit. In video fullscreen it leaves fullscreen and the video keeps playing in the page. `sendEvent:` intercepts Menu when nothing is presented, so the system does not treat it as leaving the app.

Play/Pause is the menu key. It opens the Quick Menu on press. With no video it is `UIPressTypePlayPause`, intercepted in `sendEvent:` without waiting for release, because some presses never get a matching release. When the page has video, the system no longer sends this press. It delivers the key to the page's `navigator.mediaSession`. The page script notifies native code with a `media-key` message, which opens the same menu. See `docs/play-pause-quick-menu.md`.

The touch surface is `UITouchTypeIndirect`. With pointer mode on, touch movement moves the pointer. With pointer mode off and focus on the page, the same swipe scrolls the page, with a little inertia. While the top bar or the tab overview is showing, touches do not move the pointer.

## Keyboard

A Bluetooth keyboard and the remote are the same `UIPress`. Arrow keys, Return, Escape, and similar keys are labeled by the system as arrows, Select, or Menu, so they share the remote's logic.

Other characters go through `handleHardwareKeyPress:`. It runs only when pointer mode is off and directional input is allowed. It inserts `press.key.characters` into the focused text field. Delete removes one character. With pointer mode on, these characters are ignored so typing and pointer movement do not compete for the same events.

## Gamepad

Only extended gamepads (`GCExtendedGamepad`) are attached: Xbox, PlayStation, Switch Pro, and similar controllers. Connect and disconnect use `GCControllerDidConnectNotification`. Micro gamepads (`microGamepad`, for example a remote the system exposes as a small pad) do not get these callbacks.

The system also translates the d-pad and sticks into arrow presses. `arrowPressIsFromGamepad` drops those arrow presses when a connected pad's d-pad or stick is moving, and the pad's own state drives the pointer. For a short time after the stick returns to center, late arrow presses are dropped too.

| Gamepad | What it does in the browser |
| --- | --- |
| D-pad, left stick | Move the pointer. Holding L2 or R2 speeds it up |
| Right stick | Scroll the page |
| A | Confirm. The Select press the system synthesizes is unreliable, so the button press clicks again; whichever arrives first wins |
| B | Cancel. The button is the source of truth and fills in a Menu press that may have been lost |
| Right face button (Xbox Y, PS triangle, Switch X) | Quick Menu. The system translates it into play/pause, and that press is ignored |
| Left face button (Xbox X, PS square, Switch Y) | Fullscreen the video under the pointer. The following play/pause press is ignored for 0.4 seconds |
| L1 / LB | History back |
| R1 / RB | History forward |
| − / Create / View, short press released | Quick Menu |
| Same key held about 0.7 seconds | Toggle Game Mode. The system's screen-recording gesture on this key is disabled |

With Game Mode on, the gamepad no longer moves the pointer. Every frame, and every button change, writes buttons, triggers, and sticks into the page's Gamepad API (`window.__tvb.pad`). At the same time `sendEvent:` drops presses whose type is between the arrow keys and play/pause. Otherwise B still becomes Menu and takes the user out of the page. Turning Game Mode off sends a disconnect to the page.

## Mouse

There is no separate mouse device object. If the system reports a mouse or trackpad as touches, those touches take the same `touchesMoved` path as the remote touch surface. Movement moves the browser's own pointer only while pointer mode is on. Otherwise the touches continue to the page.

A "click" on the page is not a system mouse-down. After the confirm key is released, the page script dispatches `pointerdown` / `pointerup` at the pointer's document coordinates, with `pointerType` `mouse`.

## After the shared logical keys

Device differences end in `BrowserRemoteInputController`. After that, only these actions reach `ViewController`:

- Move the pointer, or move focus by direction while in focus mode
- Confirm: click the element at the pointer
- Cancel: go back, exit fullscreen, or ask to quit when there is no history
- Menu: open or close the Quick Menu
- Scroll the page
- History forward and back
- In video fullscreen: left and right seek, confirm pauses or plays

When the top bar has focus, the tab overview is open, or a non-alert UI is presented, those surfaces handle the actions and the page pointer does not move.

## Commands each of the three channels supports

A "command" on a channel is a signal the browser actually handles, not every physical key on the device. An action the system never delivers on that channel is invisible here.

### Touches

Only movement in pointer mode is handled. `UIPanGestureRecognizer` accepts only `UITouchTypeIndirect` (the remote touch surface). While the top bar or the tab overview is showing, neither surface takes the touches.

| Signal | Command |
| --- | --- |
| Touch movement with pointer mode on | Move the pointer |
| Touch movement in video fullscreen | Consume it; do not move the pointer |
| Indirect touch swipe with pointer mode off | Scroll the page, with inertia after release |
| Any other touch | Not handled; pass it to `WKWebView` |

There is no touch-click command. Confirm comes from Select on the press channel.

### Presses

`UIPress`. The remote, the keyboard, and presses tvOS synthesizes from a gamepad all enter here. With Game Mode on, presses from the arrow keys through play/pause are dropped entirely in `sendEvent:`.

| Signal | Command |
| --- | --- |
| Up / Down / Left / Right, pressed and held | Move the pointer; longer holds move faster. With pointer mode off, move focus by direction |
| Up, pointer at the top edge | Move focus into the top bar |
| Up or Down pressed again in the same direction within 0.4 seconds | Scroll about 0.6 of a screen; holding continues the scroll |
| Left / Right in video fullscreen | Seek back or forward 10 seconds; holding seeks continuously |
| Select, released | Click the element under the pointer. If the top bar is focused, give it to the top bar |
| Menu, intercepted on press, performed on release | Leave the top bar, close the tab overview or a presented UI, exit video fullscreen, otherwise go back; ask to quit when there is no history |
| Play/Pause, pressed | Open the Quick Menu. Release does not run it a second time. In the native fullscreen player it pauses or plays instead |
| A character with `press.key`, pointer mode off | Insert it into the current text field |
| Delete / Backspace, pointer mode off | Delete one character |
| Arrow presses from a gamepad (d-pad or stick moving, or just moved) | Drop them. The same action is already handled by `GCController` |

When the page has video, play/pause often does not appear in this table. It goes through `navigator.mediaSession` instead. The command is still "open the Quick Menu."

### GCController callbacks

Attached only to `GCExtendedGamepad`. Micro gamepads do not get these callbacks. The triggers' `pressedChangedHandler` is cleared. Triggers only change pointer speed; they are not keys of their own.

| Signal | Command |
| --- | --- |
| D-pad | Same as the remote arrows: move the pointer, double-tap to scroll, enter the top bar at the top edge, seek left and right in fullscreen |
| Left stick, deflection above 0.25 | Move the pointer; speed grows with deflection. Past about 0.7 it also counts as a directional "press": seek in fullscreen, or enter the top bar at the top edge |
| L2 / R2 travel | Raise d-pad and left-stick pointer speed up to about 4.5x. No separate press command |
| Right stick, deflection above 0.3 | Scroll the page by deflection |
| A, 0.12 seconds after release | Click if no Select press already clicked in that window |
| B, 0.12 seconds after release | Run cancel if no Menu press was already handled in that window |
| L1 / LB, pressed | History back |
| R1 / RB, pressed | History forward |
| Right face button (Xbox Y, PS triangle, Switch X), pressed | Open the Quick Menu |
| Left face button (Xbox X, PS square, Switch Y), pressed | Fullscreen the video under the pointer. Play/pause presses for the next 0.4 seconds are ignored |
| − / Create / View, released before 0.7 seconds | Open the Quick Menu |
| Same key held for 0.7 seconds | Toggle Game Mode |
| Any element change while Game Mode is on | Immediately give the button state to the page's Gamepad API |
| Sticks and triggers, Game Mode on, every frame | Give the analog values to the page |
| + / Options / Menu, Home, L3, R3, touchpad click | No browser command while browsing. In Game Mode they go to the page with the rest of the state |

While browsing, arrow presses produced at the same time as the d-pad and sticks are dropped on the press channel so the pointer is not pushed twice.

## Features the browser supports today

These features are triggered by the commands above, or by an item in the Quick Menu. The Quick Menu itself is opened by the menu command.

| Feature | How to use it |
| --- | --- |
| Move the pointer and click | Arrows or touch move the pointer. Select or A clicks. A click does not enter fullscreen on its own |
| Move focus with the arrows | With pointer mode off, the arrows move between focusable elements |
| Scroll | Double-tap Up/Down, right stick, pointer at the screen edge, or a touch-surface swipe with pointer mode off |
| Back and forward | Cancel goes back. The Quick Menu has back and forward. Gamepad L1 goes back, R1 goes forward |
| Open a URL or search with Google | Quick Menu |
| Reload | Quick Menu |
| Show or hide the top bar | Press Up with the pointer at the top edge, or use the Quick Menu |
| Video fullscreen, exit fullscreen | First item in the Quick Menu, or the gamepad's left face button. In fullscreen, cancel exits, left and right seek, Select pauses or plays |
| Ad block toggle | Quick Menu; the page reloads after the toggle |
| Bookmarks | The Quick Menu lists favorites; the current site can be removed when it is already saved |
| More options | The Quick Menu opens the older advanced menu |
| Text input | With pointer mode off, keyboard characters go into the focused text field |
| Game Mode | Hold the gamepad − / Create / View, or use the Quick Menu (shown only while a gamepad is connected). The page reads the whole pad through the Gamepad API |
| New-window links | Do not open a new tab; open in the current page |

There is no separate mouse-button feature. If the system reports a mouse as touches, the only results are "move the pointer" or "give it to the page."

## Device input mapped to features

The same cell means different things on different surfaces. The table is the result while browsing a page, with pointer mode on and video fullscreen off. Differences for video fullscreen, the top bar, and an open Quick Menu follow the table.

| Input | Remote | Keyboard | Extended gamepad | Mouse or trackpad |
| --- | --- | --- | --- | --- |
| Direction | Arrows: move the pointer | Arrows: move the pointer | D-pad and left stick: move the pointer. L2 / R2 speed it up | — |
| Swipe | Touch surface: move the pointer | — | Right stick: scroll | When reported as touches: move the pointer |
| Confirm | Select: click | Return, when the system treats it as Select: click | A: click | No separate click; if a button is treated as Select, it clicks |
| Cancel | Menu: back | Escape, when the system treats it as Menu: back | B: back | — |
| Menu | Play/Pause: Quick Menu. With video it arrives through the media session | No matching key unless the system reports it as play/pause | Right face button, or a short − / Create / View: Quick Menu | — |
| Fullscreen video | First Quick Menu item | Same as the remote; the Quick Menu must be opened first | Left face button, or the Quick Menu | — |
| History | Back and forward in the Quick Menu; Menu only goes back | Same as the remote | L1 back, R1 forward; B only goes back | — |
| Double-tap Up or Down | Scroll | Scroll | D-pad double-tap: scroll | — |
| Characters, Delete | — | Type or delete with pointer mode off | — | — |
| Game Mode | Not supported | Not supported | Hold − / Create / View | Not supported |
| Other keys | — | Ignored while pointer mode is on | +, Home, L3, R3, touchpad: ignored while browsing; given to the page in Game Mode | Keys the system does not report separately: ignored |

In video fullscreen: left and right become seek, Select becomes pause/play, Menu or B leaves fullscreen, and play/pause plus the gamepad's right face button still open the Quick Menu.

With the Quick Menu or the top bar open: direction and Select go to that surface, and Menu or B closes it. Pressing play/pause again also closes the Quick Menu. Repeated media-session reports do not close it.
