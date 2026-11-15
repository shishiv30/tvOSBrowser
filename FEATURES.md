# tvOS Browser Feature Implementation Notes

Describes the behavior in the current code, where the core changes live, and which parts have not yet been confirmed on a real device.

Installation: in Xcode, press Run with **Living Room** (the Apple TV) selected. `xcodebuild` only compiles; it does not install onto the TV.

## Key Mapping

The remote and gamepads share the same logical keys. The gamepad D-pad, A, B and X are converted by tvOS into direction, Select, Menu and Play/Pause, so they enter through the same entry point as the remote. The code no longer attaches separate A / B callbacks (previously both A and B were bound to Confirm, so B triggered Cancel and Confirm at the same time).

| Logical key | Remote | Gamepad |
| --- | --- | --- |
| Direction (move pointer) | Arrow keys / touch surface | D-pad, left stick; hold a trigger (LT / RT) to speed up |
| Scroll page | Quickly press Up / Down twice | Right stick, or quickly press D-pad Up / Down twice |
| Confirm | Select | A |
| Cancel | Menu | B (**+** is also the system Menu) |
| Menu | Play/Pause | X, Y, **−** (short press) |
| Game Mode toggle | — | Hold **−** for 0.7 seconds |

- Entry points: `handlePressesBegan` / `handlePressesEnded` in `BrowserRemoteInputController.m`
- Y and **−** are not converted into key presses by the system; they are routed to `handleFunctionKey` in `attachGamepadHandlers`
- **The gamepad D-pad, left stick and triggers read the controller state directly (GameController) instead of the arrow-key events that tvOS synthesizes.** Reason: tvOS converts the left stick into arrow-key presses, and if the stick does not return to center (drift) that press never ends, so the pointer keeps running in one direction. Now, when an arrow press arrives while the gamepad D-pad is held or the left stick is off-center, the press is treated as coming from the gamepad and discarded (`arrowPressIsFromGamepad`). Remote arrow keys are unaffected.
  - D-pad: `dpad.valueChangedHandler` → `beginDirection:` / `endDirection:`, using the same logic as the remote arrow keys (double-press scroll, fullscreen seek and entering the top bar all work).
  - Left stick: dead zone 0.25, with no movement at all inside the dead zone to absorb drift; outside the dead zone speed scales linearly with deflection (`handleScrollStickDisplayLink`). Pushing past 0.7 also counts as one "press": in fullscreen it seeks forward / backward, and with the pointer at the top edge, pushing up enters the top bar.
  - Speed: the D-pad and left stick default to about 320 pt/s (slow). Holding LT or RT multiplies this up to 4.5x (about 1440 pt/s), proportional to how far the trigger is pressed. The remote arrow keys still accelerate automatically while held.

| State | Direction | Confirm | Cancel | Menu |
| --- | --- | --- | --- | --- |
| Browsing a page | Move pointer; pushing into a screen edge scrolls the page | Click; clicking a video plays it fullscreen | Go back; asks whether to quit when there is no history | Open Quick Menu |
| Video fullscreen | Left / right seeks back / forward 10 seconds; hold to keep seeking | Pause / play | Exit fullscreen; the video keeps playing in the page | Open Quick Menu |
| Quick Menu | Select | Run | Close menu | Close menu |

Confirm now takes effect on press. It used to wait 0.3 seconds to detect a double click; that wait has been removed, and the Play/Pause double-press gesture has been removed too. The Advanced Menu is now reached from **More Options** in the Quick Menu.

## Game Mode (gamepad input handed to the web page)

Hold the gamepad's "select" button for 0.7 seconds to toggle; hold again to switch back. A hint at the bottom of the screen shows the current state. It can also be entered from **Game Mode** in the Quick Menu (only shown when a gamepad is connected, because only a gamepad can exit it).

| | Switch Pro | PS5 DualSense | Xbox |
| --- | --- | --- | --- |
| Toggle button (hold) | **−** | **Create** (left of the touchpad) | **View** (⧉) |
| Same button, short press | Menu while browsing; passed to the page as Select in Game Mode | Same | Same |

While Game Mode is on:

- The gamepad no longer controls the browser: no pointer movement, no clicks, no back, no menu, no scrolling. The pointer and top bar are hidden.
- tvOS still converts A / B / X / D-pad into remote key events; these events are dropped entirely at the entry of `UIApplication+BrowserSelectPressForwarding.m` (otherwise pressing B would quit the app). A side effect is that **the remote does not work in Game Mode either**; the only way out is to hold the toggle button on the gamepad. Game Mode exits automatically when the gamepad disconnects.
- Any button change (GameController `valueChangedHandler`) is pushed to the page script immediately, and analog stick and trigger values are pushed once per frame (`gamepadScriptForController:` → `__tvb.pad`). The page reads them through the standard Gamepad API: `navigator.getGamepads()` and the `gamepadconnected` / `gamepaddisconnected` events. Pages inside cross-origin iframes receive them too.
- While Game Mode is off the page sees no gamepad at all, so using a gamepad to browse never triggers actions in the page by accident.

**Preventing dropped presses.** Two things in the browser can swallow a very short press, and both are handled:

1. If native code only polled the gamepad once per frame, a tap pressed and released between two frames would be invisible. Button changes are now sent straight from the GameController callback instead of relying on polling.
2. The "pressed" and "released" messages can arrive in the same frame of the page, and the page reads only once per frame, so it would see "not pressed". The page script has a latch (`padHeld`): if a press is released before the page has read it, it stays pressed until the page has read it once.

**Gamepad test page.** **Gamepad Test** in the bookmarks (address `tvbrowser://gamepad-test`, backed by the bundled `GamepadTest.html`). It shows the live state of every button, trigger and stick, plus three D-pad counters: ① presses reported by GameController, ② presses delivered to the page, ③ presses the page read when polling each frame. Press each direction a fixed number of times and compare: if ① is already lower than the number of presses, the signal was lost in the controller / Bluetooth / system stage and the browser can do nothing about it; only ② lower than ①, or ③ lower than ②, is a browser problem. Press L3 + R3 together to reset.

Why WebKit's built-in Gamepad support is not used: we do not control it (it cannot be switched on and off, and there is no guarantee that the WebKit on tvOS has the feature enabled), so the page script takes over `navigator.getGamepads` and native code feeds it the data.

Button indices follow the W3C "standard" layout and are by **position**, not by letter:

| Index | Position | Switch Pro | PS5 | Xbox |
| --- | --- | --- | --- | --- |
| 0 | Bottom | B | ✕ | A |
| 1 | Right | A | ○ | B |
| 2 | Left | Y | □ | X |
| 3 | Top | X | △ | Y |
| 4 / 5 | Shoulder | L / R | L1 / R1 | LB / RB |
| 6 / 7 | Trigger (analog) | ZL / ZR | L2 / R2 | LT / RT |
| 8 | Select | − | Create | View |
| 9 | Start | + | Options | Menu |
| 10 / 11 | Stick press | L3 / R3 | L3 / R3 | L3 / R3 |
| 12–15 | D-pad up / down / left / right | | | |
| 16 | Home | Home | PS | Xbox |
| 17 | Touchpad press | — | Yes | — |

Axes: 0 / 1 are the left stick X / Y, 2 / 3 are the right stick X / Y; right and down are positive.

On Switch controllers the A/B and X/Y letter positions are the opposite of Xbox. GameController reports buttons by letter, so when a Nintendo controller is detected the code swaps them (`nintendoLayout`), which guarantees that the bottom button is always index 0. The controller type is determined from keywords in `productCategory` / `vendorName` and the controller class name (`kindOfController:`).

## Page Scrolling

Three ways, all in `BrowserRemoteInputController.m`:

- **Double-press Up / Down** (remote arrow keys or gamepad D-pad): pressing the same direction twice within 0.4 seconds smoothly scrolls 0.6 of a screen. If the second press is held, continuous scrolling starts after 0.4 seconds at about 1500 pt/s. After a scroll, each further quick press in the same direction scrolls another 0.6 screen.
- **Gamepad right stick**: scrolls the page in all four directions, dead zone 0.3 (deliberately large to prevent drift), about 2600 pt/s at full deflection (`handleScrollStickDisplayLink`).
- **Pointer pushed against a screen edge**: see the "Pointer" section below.

The scrollable area under the pointer is scrolled first; if it cannot scroll, the whole page scrolls (`scrollBy` / `page` in the page script). No scrolling happens while a video is fullscreen.

## New Tabs

No new tab is opened. Links with `target="_blank"` and `window.open` navigate directly in the current tab (`createNewTabWithRequest:` in `BrowserTabCoordinator` actually loads in the current web view).

## Video Fullscreen (in-page fullscreen)

Video URLs are no longer handed to AVPlayer. On sites such as Bilibili, YouTube and Douyin the URL is a `blob:`, which AVPlayer cannot open; this was the cause of the earlier "empty player". Now the injected page script stretches the `<video>` to fill the whole web view, and the native side only hides the top bar and pointer and takes over the keys.

- Page script: `_Project/Browser/BrowserPageAgent.js`, injected at document start into every frame (including iframes)
- Injection and message bridge: the "Page agent, script bridge and ad blocking" section of `BrowserWebView.m`
- Native state: the "Page video full screen" section of `ViewController.m`; the top bar and pointer are hidden while `pageVideoActive` is true

Order of checks on a click (`activate`):

1. Link, button or input under the pointer: treated as a normal click.
2. The pointer is inside a video's bounds and the topmost element belongs to the same player (overlay and control layers count too): go fullscreen and play.
3. A cross-origin iframe is under the pointer: forward the click to the script inside the iframe, which repeats steps 1 and 2.
4. Anything else: click as usual and then observe for 6 seconds; if a video starts playing at the click position, or a large unmuted video starts playing, go fullscreen automatically. If the click opened a new page, the new page is observed for 8 seconds after it finishes loading.

While fullscreen, a time progress hint is shown at the bottom for 3 seconds after any action, and stays visible while paused.

When the video is inside an iframe, the iframe itself is stretched to fill the view, the video inside fills the iframe, and notification propagates up level by level.

Besides setting the video to `position: fixed`, the stretch also sets `overflow` to `visible` on all of its ancestors (except `<html>` / `<body>`). WebKit clips a fixed video using a positioned ancestor that has `overflow: hidden`; Bilibili's `.bpx-player-video-area` is exactly that case. Previously the video was already full-screen size but got clipped back into the original player box, which looked like "fullscreen not working". These styles are restored when exiting fullscreen.

## Quick Menu

Opened with the Menu key; closed with Cancel or by pressing Menu again. Contents: Back, Forward, Enter Address, Refresh, Hide Top Bar, Ad Block toggle, Game Mode (only when a gamepad is connected), More Options (Advanced Menu), Bookmarks. The "video fullscreen" entry was removed: clicking a video goes fullscreen and Cancel exits, so no menu entry is needed.

The system also sends Play/Pause to the page as a media key, which paused the video when the menu opened. The page script does two things: it replaces the page's `mediaSession` play/pause handlers with no-ops, and it undoes any pause/play that appears within 1 second before or after the Menu press and was not initiated by us (`guard`).

## Ad Blocking

- Network layer: `WKContentRuleList` blocks third-party requests to about 55 common ad domains and hides common ad containers. The rules are `BrowserAdBlockDomains` / `BrowserAdBlockEncodedRules` in `BrowserWebView.m`.
- YouTube: when the page script detects an ad, it mutes the audio, seeks to the end of the ad and clicks "Skip"; the sound is restored after the ad ends.
- **Ad Block: On / Off** in the Quick Menu can turn it off (use it when a site will not load); the page refreshes automatically after toggling.

This is not a complete filter list; pre-roll ads served from a video site's own domain cannot be blocked.

## Pointer

- Speed: a single press moves about 6 pt; when held, it accelerates logarithmically from about 40 pt/s to about 960 pt/s, reaching the top in 1.4 seconds.
- The hotspot is the top-left corner of the cursor image, and it can reach the bottom-right corner of the screen.
- Edge scrolling: the part of the movement blocked by the screen edge becomes page scrolling, for both the arrow keys and the touch surface (`queueEdgeScrollByDelta`). The scrollable area under the pointer is scrolled first; if it cannot scroll, the whole page scrolls.
- Pressing Up with the pointer at the top edge: if the page has been scrolled down, it scrolls up; the pointer only enters the top bar when the page is at the very top.
- Hovering only checks whether the element is clickable; no `mouseover` is injected into the page.

## Other

- tvOS 27 launches via SceneDelegate.
- `WKWebView` is configured to play media without requiring a user gesture, because pointer clicks are synthesized DOM events.
- The old in-house player `BrowserNativeVideoPlayerViewController` is still in the project; only "Play Active Video" in the Advanced Menu still uses it.
- YouTube extraction is disabled: `kBrowserYouTubeNativeExtractionEnabled = NO` in `BrowserVideoPlaybackCoordinator.m`.

## Verification Status

Tested on Bilibili (desktop site) in the tvOS 27.2 simulator (Apple TV 4K, 1080p):

- Click a video card on the home page → the video page opens in the current tab → fullscreen starts automatically once playback begins, the picture filling 1920×1080.
- Cancel exits fullscreen, the page layout is restored, and the video keeps playing.
- Clicking the player directly in the page → fullscreen immediately.
- The page script's `page` / `scrollBy` can scroll the page.

The web-page side of Game Mode was tested with simulated gamepad state (calling `__tvb.pad` directly): hardwaretester.com/gamepad recognizes the Pro Controller and DualSense, and buttons, analog trigger values, stick axes and the touchpad button are all shown correctly; it is recognized the same way inside a cross-origin iframe; after turning Game Mode off the page receives the disconnect event. The built-in test page opens normally; 5 simulated taps where "press and release arrive in the same frame" were all read by the page (all recovered by the latch), and the three counters agree.

The simulator cannot connect a gamepad or remote, so the following were only compiled, never actually pressed:

0. **The native side of Game Mode.** Holding the toggle button, reading each button of a real gamepad, the Nintendo A/B swap, and recognition of the three controller types have not been tried with a real gamepad. The Home button (index 16) will most likely be taken by tvOS itself.

1. **Gamepad D-pad, left stick, trigger acceleration, right-stick scrolling, double-press Up / Down scrolling.** The logic is described above but has not been tried on a real device. If the left stick drift exceeds the 0.25 dead zone, the pointer will still creep slowly; raise `kBrowserCursorStickDeadZone`.
2. **Fullscreen on YouTube, Douyin and kubb.** Only Bilibili was regression-tested this time.
3. **Gamepad A / B positions.** This depends on which physical key tvOS reports as A. If Confirm and Cancel turn out to be reversed, another swap needs to be added; none is written yet.
4. **Gamepad +.** The system treats it as Menu, so it is currently Cancel, not Menu.
5. **The video not pausing when the Quick Menu opens.** Both safeguards are written, but it is not yet known which one takes effect.
6. **Whether the ad rules compile successfully.** On failure the log contains `[AdBlock] rule compilation failed`.
7. Free Personal Team signing expires after about 7 days and requires running again.
