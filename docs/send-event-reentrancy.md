# Nested sendEvent freezes the app

A synthetic click on many sites used to freeze the whole app. The remote stopped working until the process was killed.

## What you see

Select under the pointer clicks the page. On some sites the click runs, then the app no longer responds to the remote, the touch surface, or the keyboard. The main thread is stuck inside `UIApplication sendEvent:`.

## Why

`UIApplication+BrowserSelectPressForwarding.m` replaces `sendEvent:`. Every event enters `browser_sendEvent:` first, and that method calls the original implementation to deliver it.

The page click is JavaScript (`element.click()` and `dispatchEvent`) and it runs on the main thread while the Select press is still inside `sendEvent:`. WebKit then posts another event before that call returns. The new event is not a press, so it took this branch:

```objc
if (event.type != UIEventTypePresses) {
    [self browser_sendEvent:event];
    return;
}
```

That calls the original `sendEvent:` again, from inside `sendEvent:`. The nested delivery never finishes, and the app stops responding.

## What we do

`sBrowserSendEventEntered` is set for the whole call and cleared in `@finally`, including when the method returns early.

If a non-press event arrives while that flag is already set, `browser_sendEvent:` returns without forwarding it. The synthetic event is dropped. The Select press that is already being delivered still runs, and a later real press is handled normally because the flag is clear again.

Press events are still handled when they arrive nested. Only the non-press event that WebKit injects during the click is dropped.
