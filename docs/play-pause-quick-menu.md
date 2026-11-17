# Play/Pause and the Quick Menu on the Older Remote

The play/pause key on the older Apple TV remote opens the Quick Menu. A tap and a long press are the same key. The menu opens on the press and does not wait for release.

## What you see

On a homepage with no video, the key opens the Quick Menu. As soon as the page has video (the app's own fullscreen is not required), the same key does nothing. The menu does not appear, and the app's press log has no entry for that key.

## Why

tvOS sends this key down two completely different paths, depending on whether a player on the page has taken over the media keys.

With no video, it is a normal press, `UIPressTypePlayPause`. `UIApplication`'s `sendEvent:` can see it (press type 6) and hands it to `BrowserRemoteInputController`, which opens the menu.

With video, the system no longer sends that press. WebKit gives it to the page's `navigator.mediaSession`, with the action `pause` (both a tap and a long press). `sendEvent:`, `pressesBegan`, and `MPRemoteCommandCenter` never receive it. It is visible only in the media session's `play` / `pause` / `stop` handlers.

Intercepting play/pause only in `pressesBegan` or `sendEvent:` therefore works on the homepage. A page with video never reaches that code.

`BrowserPageAgent.js` already replaced the media session's play, pause, and stop handlers with empty functions, so this key would not pause the video. The empty functions ate the key, and native code never learned that anyone had pressed it.

## What we do

Both paths open the same menu.

1. When the press is still delivered: `UIApplication+BrowserSelectPressForwarding.m` swallows `UIPressTypePlayPause` in `sendEvent:` and calls `BrowserPlayPausePressPerform` immediately on the press. It cannot wait for release, because some presses never get a matching release. The native fullscreen player is the exception: there the key still pauses or plays.
2. When the media session takes the key: the media-session handlers in `BrowserPageAgent.js` notify native code with `postNative({ type: 'media-key', action })`. `ViewController`'s `webView:didReceiveAgentMessage:` opens the Quick Menu on `play`, `pause`, or `stop`, and first calls `browserRemoteInputControllerFunctionKeyDown` so the page script undoes the pause the system also issued.

The media session reports the same key repeatedly in a short window (each frame on the page reports once, and holding the key repeats). Repeats within 0.8 seconds are ignored. Once the menu is showing, those reports do not close it. Otherwise a burst of `pause` would close the menu that just opened.

## How to tell which path you are on

Look at the Xcode console or the app's own press log:

- `UIPressTypePlayPause` (type 6) appears: the press intercept handled it.
- Only `media-key` / `pause`, and no type 6: the media session handled it. Changing `pressesBegan` will not help.
- Neither appears: the system kept the key earlier. Do not start by changing the menu itself.
