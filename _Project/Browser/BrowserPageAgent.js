// Injected at document start into every frame (see BrowserWebView.m).
// Owns in-page video fullscreen, playback commands, edge scrolling and ad skipping.
// Native talks to the top frame through window.__tvb; frames talk to each other with postMessage.
(function () {
    'use strict';
    if (window.__tvb) { return; }

    var T = {
        active: false,
        element: null,
        kind: '',
        saved: [],
        watchUntil: 0,
        watchPoint: null,
        selfUntil: 0,
        guardUntil: 0
    };
    try {
        Object.defineProperty(window, '__tvb', { value: T, enumerable: false, configurable: false, writable: false });
    } catch (error) {
        window.__tvb = T;
    }

    var isTop = (function () { try { return window.top === window; } catch (error) { return false; } })();
    var MAX_Z = '2147483647';
    var INTERACTIVE = 'a[href],button,input,select,textarea,label,summary,[role="button"],[role="link"],[role="slider"],[role="menuitem"],[role="tab"],[contenteditable=""],[contenteditable="true"]';

    var VIDEO_PROPS = [
        ['position', 'fixed'], ['left', '0px'], ['top', '0px'], ['right', 'auto'], ['bottom', 'auto'],
        ['width', '100vw'], ['height', '100vh'], ['max-width', 'none'], ['max-height', 'none'],
        ['min-width', '0px'], ['min-height', '0px'], ['margin', '0px'], ['z-index', MAX_Z],
        ['background-color', '#000'], ['object-fit', 'contain'], ['transform', 'none'], ['opacity', '1'],
        ['visibility', 'visible'], ['display', 'block'], ['clip-path', 'none']
    ];
    var FRAME_PROPS = VIDEO_PROPS.filter(function (pair) { return pair[0] !== 'object-fit'; });
    var ANCESTOR_PROPS = [
        ['transform', 'none'], ['filter', 'none'], ['-webkit-backdrop-filter', 'none'], ['backdrop-filter', 'none'],
        ['perspective', 'none'], ['contain', 'none'], ['content-visibility', 'visible'], ['container-type', 'normal'],
        ['will-change', 'auto'], ['clip-path', 'none'], ['-webkit-mask-image', 'none'], ['opacity', '1'],
        ['visibility', 'visible'], ['z-index', MAX_Z]
    ];
    // WebKit clips a fixed video to any positioned ancestor that hides its overflow (bilibili's player
    // box does). <html>/<body> are left alone so the page keeps its own scrolling behaviour.
    var CLIPPING_ANCESTOR_PROPS = ANCESTOR_PROPS.concat([
        ['overflow', 'visible'], ['overflow-x', 'visible'], ['overflow-y', 'visible'],
        ['clip', 'auto'], ['-webkit-mask', 'none'], ['mask', 'none'], ['border-radius', '0px']
    ]);

    function now() { return Date.now(); }

    function postNative(message) {
        try {
            window.webkit.messageHandlers.tvb.postMessage(message);
        } catch (error) {}
    }

    function post(target, message) {
        if (!target) { return; }
        message.__tvb = 1;
        try { target.postMessage(message, '*'); } catch (error) {}
    }

    function parentOf(node) {
        if (!node) { return null; }
        if (node.parentElement) { return node.parentElement; }
        var root = node.getRootNode ? node.getRootNode() : null;
        return root && root.host ? root.host : null;
    }

    function collect(selector) {
        var out = [];
        function visit(root, depth) {
            var matches;
            try { matches = root.querySelectorAll(selector); } catch (error) { return; }
            for (var i = 0; i < matches.length; i++) { out.push(matches[i]); }
            if (depth > 4) { return; }
            var all = root.querySelectorAll('*');
            for (var j = 0; j < all.length; j++) {
                if (all[j].shadowRoot) { visit(all[j].shadowRoot, depth + 1); }
            }
        }
        visit(document, 0);
        return out;
    }

    function deepElementFromPoint(x, y) {
        var element = document.elementFromPoint(x, y);
        for (var i = 0; element && element.shadowRoot && i < 8; i++) {
            var inner = element.shadowRoot.elementFromPoint ? element.shadowRoot.elementFromPoint(x, y) : null;
            if (!inner || inner === element) { break; }
            element = inner;
        }
        return element;
    }

    function area(rect) { return Math.max(0, rect.width) * Math.max(0, rect.height); }

    function contains(rect, x, y) {
        return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
    }

    function hasSource(video) {
        return video.readyState > 0 || !!video.currentSrc || !!video.src || !!video.srcObject || !!video.querySelector('source');
    }

    function usable(video) {
        if (!video || !video.isConnected) { return false; }
        var rect = video.getBoundingClientRect();
        if (rect.width < 120 || rect.height < 68) { return false; }
        if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= window.innerHeight || rect.left >= window.innerWidth) { return false; }
        var style = window.getComputedStyle(video);
        return style.visibility !== 'hidden' && style.display !== 'none';
    }

    function isPlaying(video) { return !video.paused && !video.ended && video.readyState > 1; }

    function interactiveAncestor(element) {
        for (var node = element, i = 0; node && i < 12; node = parentOf(node), i++) {
            if (node.matches && node.matches(INTERACTIVE)) { return node; }
        }
        return null;
    }

    // The video counts as "under the cursor" when the hit element is the video,
    // or an overlay that belongs to the same player box.
    function belongsToPlayer(hit, video) {
        if (!hit || hit === video) { return true; }
        var videoArea = area(video.getBoundingClientRect());
        for (var node = hit, i = 0; node && i < 10; node = parentOf(node), i++) {
            var holdsVideo = false;
            try { holdsVideo = node.contains(video) || (node.shadowRoot && node.shadowRoot.contains(video)); } catch (error) {}
            if (holdsVideo) {
                return area(node.getBoundingClientRect()) <= videoArea * 2.2;
            }
        }
        return false;
    }

    function videoAtPoint(x, y, hit) {
        var best = null;
        var bestScore = -1;
        collect('video').forEach(function (video) {
            if (!usable(video) || !hasSource(video)) { return; }
            var rect = video.getBoundingClientRect();
            if (!contains(rect, x, y) || !belongsToPlayer(hit, video)) { return; }
            var score = area(rect) + (isPlaying(video) ? 1e9 : 0);
            if (score > bestScore) { bestScore = score; best = video; }
        });
        return best;
    }

    function bestVideo(requirePlaying) {
        var best = null;
        var bestScore = -1;
        collect('video').forEach(function (video) {
            if (!usable(video) || !hasSource(video)) { return; }
            var playing = isPlaying(video);
            if (requirePlaying && !playing) { return; }
            var score = area(video.getBoundingClientRect()) + (playing ? 1e9 : 0) + (video.muted ? 0 : 1e8);
            if (score > bestScore) { bestScore = score; best = video; }
        });
        return best;
    }

    // ---- fullscreen -------------------------------------------------------

    function applyProps(element, props, remember) {
        var style = element.style;
        if (!style) { return; }
        var record = remember ? { element: element, values: [] } : null;
        for (var i = 0; i < props.length; i++) {
            var name = props[i][0];
            if (record) { record.values.push([name, style.getPropertyValue(name), style.getPropertyPriority(name)]); }
            if (style.getPropertyValue(name) !== props[i][1] || style.getPropertyPriority(name) !== 'important') {
                style.setProperty(name, props[i][1], 'important');
            }
        }
        if (record) { T.saved.push(record); }
    }

    function restoreProps() {
        for (var i = T.saved.length - 1; i >= 0; i--) {
            var record = T.saved[i];
            var style = record.element.style;
            if (!style) { continue; }
            for (var j = 0; j < record.values.length; j++) {
                var entry = record.values[j];
                if (entry[1]) { style.setProperty(entry[0], entry[1], entry[2]); }
                else { style.removeProperty(entry[0]); }
            }
        }
        T.saved = [];
    }

    var keeperTimer = 0;
    var styleObserver = null;
    var missingTicks = 0;

    function elementProps() { return T.kind === 'video' ? VIDEO_PROPS : FRAME_PROPS; }

    function keep() {
        if (!T.active) { return; }
        var element = T.element;
        if (!element || !element.isConnected) {
            var replacement = T.kind === 'video' ? bestVideo(true) : null;
            if (replacement) {
                exitLocal(true);
                enter(replacement, 'video');
                return;
            }
            missingTicks += 1;
            if (missingTicks >= 6) { exitLocal(false); }
            return;
        }
        missingTicks = 0;
        applyProps(element, elementProps(), false);
        if (T.kind === 'video') { refreshHud(); }
    }

    function notify(active) {
        if (isTop) { postNative({ type: 'fs', active: active }); }
        else { post(window.parent, { type: active ? 'fs-enter' : 'fs-exit' }); }
    }

    function enter(element, kind) {
        if (T.active) {
            if (T.element === element) { return; }
            exitLocal(true);
        }
        T.active = true;
        T.element = element;
        T.kind = kind;
        T.saved = [];
        T.watchUntil = 0;
        missingTicks = 0;
        applyProps(element, elementProps(), true);
        for (var node = parentOf(element), i = 0; node && i < 60; node = parentOf(node), i++) {
            var isRoot = node === document.documentElement || node === document.body;
            applyProps(node, isRoot ? ANCESTOR_PROPS : CLIPPING_ANCESTOR_PROPS, true);
        }
        clearInterval(keeperTimer);
        keeperTimer = setInterval(keep, 400);
        try {
            styleObserver = new MutationObserver(function () {
                if (T.active && T.element === element) { applyProps(element, elementProps(), false); }
            });
            styleObserver.observe(element, { attributes: true, attributeFilter: ['style'] });
        } catch (error) {}
        if (kind === 'video') {
            if (element.paused) { play(element); }
            showHud(2500);
        }
        notify(true);
    }

    function exitLocal(silent) {
        if (!T.active) { return; }
        var element = T.element;
        var kind = T.kind;
        clearInterval(keeperTimer);
        keeperTimer = 0;
        if (styleObserver) { try { styleObserver.disconnect(); } catch (error) {} styleObserver = null; }
        restoreProps();
        T.active = false;
        T.element = null;
        T.kind = '';
        T.watchUntil = 0;
        hideHud();
        if (kind === 'frame' && element) {
            try { post(element.contentWindow, { type: 'exit' }); } catch (error) {}
        }
        try { window.dispatchEvent(new Event('resize')); } catch (error) {}
        if (!silent) { notify(false); }
    }

    // ---- playback ---------------------------------------------------------

    function play(video) {
        T.selfUntil = now() + 500;
        try {
            var promise = video.play();
            if (promise && promise.catch) { promise.catch(function () {}); }
        } catch (error) {}
    }

    function pause(video) {
        T.selfUntil = now() + 500;
        try { video.pause(); } catch (error) {}
    }

    function runCommand(name, value) {
        if (!T.active) { return 'none'; }
        if (T.kind === 'frame') {
            try { post(T.element.contentWindow, { type: 'cmd', name: name, value: value }); } catch (error) {}
            return 'frame';
        }
        var video = T.element;
        if (!video) { return 'none'; }
        if (name === 'toggle') {
            if (video.paused || video.ended) { play(video); } else { pause(video); }
        } else if (name === 'seek') {
            var target = (video.currentTime || 0) + Number(value || 0);
            if (isFinite(video.duration) && video.duration > 0) { target = Math.min(target, Math.max(0, video.duration - 0.5)); }
            try { video.currentTime = Math.max(0, target); } catch (error) {}
        }
        showHud(3000);
        return 'ok';
    }

    // ---- HUD --------------------------------------------------------------

    var hud = null;
    var hudLabel = null;
    var hudFill = null;
    var hudTimer = 0;

    function formatTime(seconds) {
        if (!isFinite(seconds) || seconds < 0) { seconds = 0; }
        var total = Math.floor(seconds);
        var hours = Math.floor(total / 3600);
        var minutes = Math.floor((total % 3600) / 60);
        var secs = total % 60;
        var tail = (minutes < 10 && hours ? '0' : '') + minutes + ':' + (secs < 10 ? '0' : '') + secs;
        return hours ? hours + ':' + tail : tail;
    }

    function ensureHud() {
        if (hud && hud.isConnected) { return; }
        hud = document.createElement('div');
        hud.setAttribute('style', 'position:fixed;left:5vw;right:5vw;bottom:6vh;z-index:' + MAX_Z + ';pointer-events:none;' +
            'font:600 28px -apple-system,Helvetica,Arial,sans-serif;color:#fff;text-shadow:0 1px 4px #000;' +
            'opacity:0;transition:opacity .2s;text-align:left;line-height:1.4');
        hudLabel = document.createElement('div');
        var track = document.createElement('div');
        track.setAttribute('style', 'margin-top:10px;height:6px;border-radius:3px;background:rgba(255,255,255,.3);overflow:hidden');
        hudFill = document.createElement('div');
        hudFill.setAttribute('style', 'height:100%;width:0;background:#fff');
        track.appendChild(hudFill);
        hud.appendChild(hudLabel);
        hud.appendChild(track);
        (document.documentElement || document.body).appendChild(hud);
    }

    function refreshHud() {
        if (!hud || !T.active || T.kind !== 'video') { return; }
        var video = T.element;
        var duration = video.duration;
        var hasDuration = isFinite(duration) && duration > 0;
        var text = (video.paused ? '❚❚  ' : '▶  ') + formatTime(video.currentTime);
        if (hasDuration) { text += ' / ' + formatTime(duration); }
        hudLabel.textContent = text;
        hudFill.style.width = hasDuration ? Math.min(100, (video.currentTime / duration) * 100) + '%' : '0';
        if (video.paused) { hud.style.opacity = '1'; }
    }

    function showHud(duration) {
        if (!T.active || T.kind !== 'video') { return; }
        ensureHud();
        refreshHud();
        hud.style.opacity = '1';
        clearTimeout(hudTimer);
        hudTimer = setTimeout(function () {
            if (hud && !(T.active && T.kind === 'video' && T.element.paused)) { hud.style.opacity = '0'; }
        }, duration);
    }

    function hideHud() {
        clearTimeout(hudTimer);
        if (hud && hud.parentNode) { hud.parentNode.removeChild(hud); }
        hud = null;
    }

    // ---- click / activate / watch -----------------------------------------

    function click(x, y) {
        var target = deepElementFromPoint(x, y);
        if (!target) { return; }
        var actionable = interactiveAncestor(target) || target;
        try { if (actionable.focus) { actionable.focus(); } } catch (error) {}
        function fire(type, name) {
            try {
                var Constructor = window[name] || window.MouseEvent;
                target.dispatchEvent(new Constructor(type, {
                    bubbles: true, cancelable: true, composed: true, view: window,
                    clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: 1, pointerType: 'mouse'
                }));
            } catch (error) {}
        }
        fire('pointerdown', 'PointerEvent');
        fire('mousedown', 'MouseEvent');
        fire('pointerup', 'PointerEvent');
        fire('mouseup', 'MouseEvent');
        if (typeof target.click === 'function') { target.click(); } else { fire('click', 'MouseEvent'); }
    }

    function frameOffset(frame, x, y) {
        var rect = frame.getBoundingClientRect();
        return { x: x - rect.left - (frame.clientLeft || 0), y: y - rect.top - (frame.clientTop || 0) };
    }

    function sameOriginAgent(frame) {
        try {
            var agent = frame.contentWindow && frame.contentWindow.__tvb;
            return agent && frame.contentDocument ? agent : null;
        } catch (error) {
            return null;
        }
    }

    function qualifies(video) {
        if (!usable(video) || !hasSource(video)) { return false; }
        var rect = video.getBoundingClientRect();
        if (T.watchPoint && contains(rect, T.watchPoint.x, T.watchPoint.y)) { return true; }
        return !video.muted && rect.width >= 300 && area(rect) >= window.innerWidth * window.innerHeight * 0.12;
    }

    function scanWatch() {
        if (T.active || now() > T.watchUntil) { return false; }
        var best = null;
        var bestArea = 0;
        collect('video').forEach(function (video) {
            if (!isPlaying(video) || !qualifies(video)) { return; }
            var size = area(video.getBoundingClientRect());
            if (size > bestArea) { bestArea = size; best = video; }
        });
        if (best) { enter(best, 'video'); return true; }
        return false;
    }

    var watchTimer = 0;

    function arm(x, y, duration, cascade) {
        if (T.active) { return; }
        T.watchPoint = (x >= 0 && y >= 0) ? { x: x, y: y } : null;
        T.watchUntil = now() + duration;
        clearInterval(watchTimer);
        watchTimer = setInterval(function () {
            if (T.active || now() > T.watchUntil || scanWatch()) {
                clearInterval(watchTimer);
                watchTimer = 0;
            }
        }, 300);
        if (cascade) {
            collect('iframe').forEach(function (frame) {
                try { post(frame.contentWindow, { type: 'arm', duration: duration }); } catch (error) {}
            });
        }
        scanWatch();
    }

    function activate(x, y, clickLocally) {
        if (T.active) { return 'video'; }
        var hit = deepElementFromPoint(x, y);
        if (!hit) { return 'none'; }
        if (hit.tagName === 'IFRAME' || hit.tagName === 'FRAME') {
            var point = frameOffset(hit, x, y);
            var agent = sameOriginAgent(hit);
            if (agent) {
                var result = agent.activate(point.x, point.y, clickLocally);
                if (result === 'video') { enter(hit, 'frame'); }
                return result;
            }
            post(hit.contentWindow, { type: 'activate', x: point.x, y: point.y });
            return 'frame';
        }
        if (!interactiveAncestor(hit)) {
            var video = videoAtPoint(x, y, hit);
            if (video) {
                enter(video, 'video');
                return 'video';
            }
        }
        arm(x, y, 6000, true);
        if (clickLocally) { click(x, y); }
        return 'none';
    }

    function scrollableAt(x, y, dx, dy) {
        for (var node = deepElementFromPoint(x, y), i = 0; node && i < 40; node = parentOf(node), i++) {
            if (node === document.body || node === document.documentElement) { break; }
            var style = window.getComputedStyle(node);
            var canY = dy !== 0 && /(auto|scroll|overlay)/.test(style.overflowY) && node.scrollHeight > node.clientHeight + 1 &&
                (dy > 0 ? node.scrollTop + node.clientHeight < node.scrollHeight - 1 : node.scrollTop > 0);
            var canX = dx !== 0 && /(auto|scroll|overlay)/.test(style.overflowX) && node.scrollWidth > node.clientWidth + 1 &&
                (dx > 0 ? node.scrollLeft + node.clientWidth < node.scrollWidth - 1 : node.scrollLeft > 0);
            if (canY || canX) { return node; }
        }
        return null;
    }

    function scrollBy(x, y, dx, dy, smooth) {
        var hit = deepElementFromPoint(x, y);
        if (hit && (hit.tagName === 'IFRAME' || hit.tagName === 'FRAME')) {
            var agent = sameOriginAgent(hit);
            var point = frameOffset(hit, x, y);
            if (agent) { return agent.scrollBy(point.x, point.y, dx, dy, smooth); }
            post(hit.contentWindow, { type: 'scroll', x: point.x, y: point.y, dx: dx, dy: dy, smooth: !!smooth });
            return 'frame';
        }
        var target = scrollableAt(x, y, dx, dy);
        var options = { left: dx, top: dy, behavior: smooth ? 'smooth' : 'auto' };
        if (target) {
            try { target.scrollBy(options); } catch (error) { target.scrollLeft += dx; target.scrollTop += dy; }
            return 'element';
        }
        try { window.scrollBy(options); } catch (error) { window.scrollBy(dx, dy); }
        return 'window';
    }

    // ---- system play/pause guard ------------------------------------------
    // The remote's Play/Pause button opens the Quick Menu, but the system also
    // sends a media toggle to the page. Undo that toggle while the guard is up.

    var lastMediaEvent = null;

    function onMediaEvent(event) {
        var video = event.target;
        if (!video || video.tagName !== 'VIDEO' && video.tagName !== 'AUDIO') { return; }
        var time = now();
        if (event.type === 'playing' || event.type === 'timeupdate') {
            if (!T.active && time <= T.watchUntil && video.tagName === 'VIDEO') { scanWatch(); }
            if (T.active && T.element === video && event.type === 'timeupdate' && hud && hud.style.opacity === '1') { refreshHud(); }
            return;
        }
        if (time < T.selfUntil) { return; }
        if (time < T.guardUntil) {
            revert(video, event.type);
            return;
        }
        lastMediaEvent = { video: video, type: event.type, time: time };
    }

    function revert(video, type) {
        T.guardUntil = 0;
        if (type === 'pause' && !video.ended) { play(video); }
        else if (type === 'play') { pause(video); }
    }

    function guard(cascade) {
        var time = now();
        if (lastMediaEvent && time - lastMediaEvent.time < 400) {
            var recent = lastMediaEvent;
            lastMediaEvent = null;
            revert(recent.video, recent.type);
        } else {
            T.guardUntil = time + 900;
        }
        if (cascade) {
            collect('iframe').forEach(function (frame) {
                try { post(frame.contentWindow, { type: 'guard' }); } catch (error) {}
            });
        }
    }

    ['play', 'pause', 'playing', 'timeupdate'].forEach(function (type) {
        document.addEventListener(type, onMediaEvent, true);
    });

    try {
        var session = navigator.mediaSession;
        if (session && session.setActionHandler) {
            var originalSetActionHandler = session.setActionHandler.bind(session);
            var blocked = { play: 1, pause: 1, stop: 1 };
            Object.keys(blocked).forEach(function (action) {
                try { originalSetActionHandler(action, function () {}); } catch (error) {}
            });
            session.setActionHandler = function (action, handler) {
                if (blocked[action]) { return; }
                return originalSetActionHandler(action, handler);
            };
        }
    } catch (error) {}

    // ---- frame messaging --------------------------------------------------

    function frameForWindow(source) {
        var frames = collect('iframe');
        for (var i = 0; i < frames.length; i++) {
            try { if (frames[i].contentWindow === source) { return frames[i]; } } catch (error) {}
        }
        return null;
    }

    window.addEventListener('message', function (event) {
        var data = event.data;
        if (!data || data.__tvb !== 1 || typeof data.type !== 'string') { return; }
        var fromParent = !isTop && event.source === window.parent;
        if (data.type === 'fs-enter' || data.type === 'fs-exit') {
            var frame = frameForWindow(event.source);
            if (!frame) { return; }
            if (data.type === 'fs-enter') { enter(frame, 'frame'); }
            else if (T.active && T.element === frame) { exitLocal(false); }
            return;
        }
        if (!fromParent) { return; }
        switch (data.type) {
            case 'exit': exitLocal(true); break;
            case 'cmd': runCommand(data.name, data.value); break;
            case 'activate': activate(Number(data.x), Number(data.y), true); break;
            case 'arm': arm(-1, -1, Number(data.duration) || 6000, true); break;
            case 'best': enterBest(); break;
            case 'scroll': scrollBy(Number(data.x), Number(data.y), Number(data.dx), Number(data.dy), !!data.smooth); break;
            case 'guard': guard(true); break;
            case 'pad': setPad(data.state, true); break;
        }
    }, false);

    function enterBest() {
        var video = bestVideo(false);
        if (video) { enter(video, 'video'); return 'video'; }
        collect('iframe').forEach(function (frame) {
            try { post(frame.contentWindow, { type: 'best' }); } catch (error) {}
        });
        return 'frame';
    }

    // ---- ad skipping ------------------------------------------------------

    var host = location.hostname || '';
    if (/(^|\.)youtube(-nocookie)?\.com$/.test(host)) {
        var mutedForAd = false;
        setInterval(function () {
            var player = document.querySelector('.html5-video-player');
            if (!player) { return; }
            var video = player.querySelector('video');
            var showingAd = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
            if (showingAd) {
                var skip = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-container button');
                if (skip) { try { skip.click(); } catch (error) {} }
                if (video) {
                    if (!video.muted) { video.muted = true; mutedForAd = true; }
                    if (isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.3) {
                        try { video.currentTime = video.duration - 0.1; } catch (error) {}
                    }
                }
            } else if (mutedForAd && video) {
                video.muted = false;
                mutedForAd = false;
            }
            var overlays = document.querySelectorAll('.ytp-ad-overlay-container, .ytp-ad-message-container, ytd-ad-slot-renderer, #player-ads, #masthead-ad');
            for (var i = 0; i < overlays.length; i++) { overlays[i].style.setProperty('display', 'none', 'important'); }
        }, 400);
    }

    // ---- game controller bridge --------------------------------------------
    // In game mode the app reads the controller natively and pushes its state here; pages see it
    // through the standard Gamepad API ("standard" mapping, buttons by position). Outside game mode
    // the page sees no controller at all, so browsing with the pad never leaks into a web app.

    var padState = null;
    var padStamp = 0;
    var padFrames = [];
    var padFramesStamp = 0;
    var ownPadEvents = typeof WeakSet === 'function' ? new WeakSet() : null;

    // A press and its release can arrive between two frames of the page. `padHeld` keeps such a
    // button down until the page has read it once, so a quick tap is never invisible to a game.
    var padObserved = [];
    var padHeld = [];
    var padHeldCount = 0;
    var padReleaseScheduled = false;
    var padStats = { updates: 0, down: [], latched: 0, native: [0, 0, 0, 0] };
    T.padStats = padStats;

    function releaseHeldPad() {
        padReleaseScheduled = false;
        padHeld = [];
        padHeldCount = 0;
    }

    function buildPad(reading) {
        if (!padState) { return null; }
        var buttons = padState.b.map(function (value, index) {
            if (padHeld[index]) { value = 1; }
            if (reading && value > 0.5) { padObserved[index] = true; }
            return { pressed: value > 0.5, touched: value > 0, value: value };
        });
        if (reading && padHeldCount > 0 && !padReleaseScheduled) {
            // The page has seen the held presses now; let go once this frame is over.
            padReleaseScheduled = true;
            if (window.requestAnimationFrame) { window.requestAnimationFrame(releaseHeldPad); }
            else { setTimeout(releaseHeldPad, 0); }
        }
        return {
            id: padState.id, index: 0, connected: true, mapping: 'standard', timestamp: padStamp,
            buttons: buttons, axes: padState.a.slice(), vibrationActuator: null, hapticActuators: []
        };
    }

    function firePadEvent(type, pad) {
        try {
            var event = new Event(type);
            Object.defineProperty(event, 'gamepad', { value: pad, enumerable: true });
            if (ownPadEvents) { ownPadEvents.add(event); }
            window.dispatchEvent(event);
        } catch (error) {}
    }

    function setPad(state, cascade) {
        var previous = padState;
        var next = state && state.id && state.b && state.a ? state : null;
        padStamp = (window.performance && performance.now) ? performance.now() : now();
        if (next) {
            padStats.updates += 1;
            if (next.n) { padStats.native = next.n; }
            for (var index = 0; index < next.b.length; index++) {
                var wasDown = !!previous && previous.b[index] > 0.5;
                var isDown = next.b[index] > 0.5;
                if (isDown && !wasDown) {
                    padStats.down[index] = (padStats.down[index] || 0) + 1;
                    padObserved[index] = false;
                } else if (!isDown && wasDown && !padObserved[index] && !padHeld[index]) {
                    padHeld[index] = true;
                    padHeldCount += 1;
                    padStats.latched += 1;
                }
            }
        } else {
            releaseHeldPad();
            padObserved = [];
        }
        if (previous && (!next || next.id !== previous.id)) {
            var last = buildPad();
            last.connected = false;
            padState = null;
            firePadEvent('gamepaddisconnected', last);
        }
        padState = next;
        if (next && (!previous || previous.id !== next.id)) { firePadEvent('gamepadconnected', buildPad()); }
        if (!cascade) { return; }
        if (now() - padFramesStamp > 1000) {
            padFrames = collect('iframe');
            padFramesStamp = now();
        }
        padFrames.forEach(function (frame) {
            var agent = sameOriginAgent(frame);
            if (agent && agent.pad) { agent.pad(state); }
            else { post(frame.contentWindow, { type: 'pad', state: state }); }
        });
    }

    try {
        Object.defineProperty(Navigator.prototype, 'getGamepads', {
            configurable: true, writable: true,
            value: function () { return [buildPad(true), null, null, null]; }
        });
        // Controllers WebKit reports by itself would bypass game mode; only our own events get through.
        ['gamepadconnected', 'gamepaddisconnected'].forEach(function (type) {
            window.addEventListener(type, function (event) {
                if (!ownPadEvents || !ownPadEvents.has(event)) { event.stopImmediatePropagation(); }
            }, true);
        });
    } catch (error) {}

    // ---- native API (top frame) -------------------------------------------

    T.activate = function (x, y, clickLocally) { return activate(Number(x), Number(y), !!clickLocally); };
    T.arm = function (x, y, duration) { arm(Number(x), Number(y), Number(duration) || 6000, true); return 'ok'; };
    T.exit = function () { exitLocal(false); return 'ok'; };
    T.command = function (name, value) { return runCommand(name, value); };
    T.enterBest = function () { return enterBest(); };
    T.scrollBy = function (x, y, dx, dy, smooth) { return scrollBy(Number(x), Number(y), Number(dx), Number(dy), !!smooth); };
    // One "page" step (a fraction of the viewport height), animated.
    T.page = function (x, y, fraction) { return scrollBy(Number(x), Number(y), 0, Math.round(window.innerHeight * Number(fraction)), true); };
    T.guard = function () { guard(true); return 'ok'; };
    // state: { id: string, b: [17+ values 0..1], a: [lx, ly, rx, ry] } or null when game mode is off.
    T.pad = function (state) { setPad(state, true); return 'ok'; };
    T.state = function () { return T.active ? '1' : '0'; };

    if (isTop) { postNative({ type: 'fs', active: false }); }
})();
