/* Sidekick chat screenshot renderer.
   The host (Swift) calls window.skBootstrap(payload) once the
   page has loaded — we render the chat layout in one pass and
   then signal back when the content is fully painted so the
   host can call WKWebView.takeSnapshot. Does NOT stream. */

(function () {
    "use strict";

    var hostReady = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ready) || null;
    var hostHeight = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.heightChanged) || null;
    var hostError = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scriptError) || null;

    // Surface uncaught errors to the host so the renderer can
    // fail fast instead of waiting for its 30-second timeout.
    function reportError(message, source) {
        if (!hostError) return;
        try { hostError.postMessage({ message: String(message || ""), source: String(source || "") }); }
        catch (_) {}
    }

    window.addEventListener("error", function (e) {
        reportError((e && e.message) || "uncaught error", "window.onerror");
    });
    window.addEventListener("unhandledrejection", function (e) {
        var msg = "unhandled rejection";
        if (e && e.reason) {
            msg = (e.reason.message || String(e.reason));
        }
        reportError(msg, "unhandledrejection");
    });

    var booted = false;
    var root = null;

    // ---- Markdown-it ----------------------------------------------------

    var md = window.markdownit({
        html: false,
        linkify: true,
        typographer: false,
        breaks: false,
    });

    // Mirror chat.js: anything that isn't a network/data URL is
    // proxied through Swift via sidekick-asset:// so file paths and
    // generated images still resolve.
    var ASSET_SCHEME = "sidekick-asset";
    var defaultImageRule = md.renderer.rules.image || function (tokens, idx, options, env, self) {
        return self.renderToken(tokens, idx, options);
    };
    md.renderer.rules.image = function (tokens, idx, options, env, self) {
        var token = tokens[idx];
        var srcIdx = token.attrIndex("src");
        if (srcIdx >= 0) {
            var src = token.attrs[srcIdx][1];
            if (src && !/^(https?:|data:|blob:|sidekick-asset:)/i.test(src)) {
                token.attrs[srcIdx][1] =
                    ASSET_SCHEME + "://load?u=" + encodeURIComponent(src);
            }
        }
        // No lazy-load: the snapshot waits for every image to decode,
        // and lazy images don't paint until they're scrolled into view.
        token.removeAttr && token.removeAttr("loading");
        token.attrSet("decoding", "sync");
        return defaultImageRule(tokens, idx, options, env, self);
    };

    // ---- SF Symbol → inline SVG mapping --------------------------------

    // Stroke-based glyphs sized for a 16x16 box; the .avatar wrapper
    // scales them down via CSS. Keeps the bundle dependency-free.
    var SYMBOLS = {
        "person.fill":
            '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">'
            + '<circle cx="8" cy="5.4" r="2.9"/>'
            + '<path d="M2.6 13.4c.5-2.6 2.7-4.4 5.4-4.4s4.9 1.8 5.4 4.4c.1.5-.3.9-.8.9H3.4c-.5 0-.9-.4-.8-.9z"/>'
            + '</svg>',
        "cpu.fill":
            '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">'
            + '<rect x="3" y="3" width="10" height="10" rx="2"/>'
            + '<rect x="5.5" y="5.5" width="5" height="5" rx="0.6" fill="rgba(0,0,0,0.18)"/>'
            + '<g fill="currentColor">'
            + '<rect x="6.4" y="0.4" width="0.9" height="2"/>'
            + '<rect x="8.7" y="0.4" width="0.9" height="2"/>'
            + '<rect x="6.4" y="13.6" width="0.9" height="2"/>'
            + '<rect x="8.7" y="13.6" width="0.9" height="2"/>'
            + '<rect x="0.4" y="6.4" width="2" height="0.9"/>'
            + '<rect x="0.4" y="8.7" width="2" height="0.9"/>'
            + '<rect x="13.6" y="6.4" width="2" height="0.9"/>'
            + '<rect x="13.6" y="8.7" width="2" height="0.9"/>'
            + '</g>'
            + '</svg>',
        "wrench.and.screwdriver.fill":
            '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">'
            + '<path d="M3.1 12.7l4.6-4.6 1.4 1.4-4.6 4.6c-.4.4-1 .4-1.4 0s-.4-1 0-1.4z"/>'
            + '<path d="M11.2 1.6c1.8-.3 3.5 1.4 3.2 3.2-.2 1.2-1.3 2.1-2.5 2.1-.3 0-.6-.1-.9-.2L9.4 8.4l-1.4-1.4 1.7-1.7c-.3-1.1.3-2.3 1.5-2.6.2-.4.8-1 1.1-1.1z"/>'
            + '</svg>',
        "brain.fill":
            '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">'
            + '<path d="M5 2.2C3.5 2.2 2.4 3.4 2.4 4.8c0 .4.1.8.3 1.2C2 6.5 1.5 7.2 1.5 8.1c0 .8.4 1.5 1 1.9-.1.3-.2.6-.2.9 0 1.3 1 2.3 2.3 2.3.4 0 .7-.1 1-.2.4.6 1.1 1 1.9 1 .9 0 1.6-.5 2-1.2V2.6c-.4-.3-.8-.4-1.3-.4-.8 0-1.6.4-2 1.1-.4-.7-1.2-1.1-2.2-1.1z"/>'
            + '<path d="M11 2.2c-.5 0-.9.1-1.3.4v10.2c.4.7 1.1 1.2 2 1.2.8 0 1.5-.4 1.9-1 .3.1.6.2 1 .2 1.3 0 2.3-1 2.3-2.3 0-.3-.1-.6-.2-.9.6-.4 1-1.1 1-1.9 0-.9-.5-1.6-1.2-2.1.2-.4.3-.8.3-1.2 0-1.4-1.1-2.6-2.6-2.6-1 0-1.8.4-2.2 1.1-.4-.7-1.2-1.1-2-1.1z"/>'
            + '</svg>',
        "globe":
            '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2" aria-hidden="true">'
            + '<circle cx="8" cy="8" r="6.2"/>'
            + '<ellipse cx="8" cy="8" rx="3.1" ry="6.2"/>'
            + '<line x1="1.8" y1="8" x2="14.2" y2="8"/>'
            + '</svg>',
        "doc.fill":
            '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">'
            + '<path d="M4 1.6h5.2l3.2 3.2v9c0 .5-.4.9-.9.9H4c-.5 0-.9-.4-.9-.9V2.5c0-.5.4-.9.9-.9z"/>'
            + '<path d="M9.2 1.6V4c0 .5.4.9.9.9h2.3" fill="rgba(0,0,0,0.18)"/>'
            + '</svg>',
        "document":
            '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2" aria-hidden="true">'
            + '<path d="M4.2 1.8h5L12 4.7v9.1c0 .3-.2.6-.6.6H4.2c-.3 0-.6-.2-.6-.6V2.4c0-.3.2-.6.6-.6z"/>'
            + '<path d="M9.1 1.8v2.4c0 .3.2.6.6.6h2.4"/>'
            + '</svg>'
    };

    function symbolSVG(name) {
        if (name && SYMBOLS[name]) return SYMBOLS[name];
        return SYMBOLS["person.fill"];
    }

    // ---- Row builders ---------------------------------------------------

    function makeEl(tag, className, text) {
        var el = document.createElement(tag);
        if (className) el.className = className;
        if (text !== undefined && text !== null) el.textContent = text;
        return el;
    }

    function senderDisplayName(row) {
        if (row.senderName) return row.senderName;
        switch (row.sender) {
            case "user":      return "You";
            case "assistant": return "Assistant";
            case "system":    return "System";
            case "tool":      return "Tool";
            default:          return "Message";
        }
    }

    function buildAvatar(row) {
        var avatar = makeEl("div", "avatar");
        var fill = (row.avatar && row.avatar.fillHex) || "#7c4dff";
        var fg = (row.avatar && row.avatar.foregroundHex) || "#ffffff";
        var symbol = (row.avatar && row.avatar.symbol) || "person.fill";
        avatar.style.background = fill;
        avatar.style.color = fg;
        avatar.innerHTML = symbolSVG(symbol);
        return avatar;
    }

    function buildHeader(row) {
        var header = makeEl("div", "message-header");
        header.appendChild(makeEl("span", "sender-name", senderDisplayName(row)));
        if (row.timeLabel) {
            header.appendChild(makeEl("span", "timestamp", row.timeLabel));
        }
        if (row.modelLabel) {
            header.appendChild(makeEl("span", "model-tag", row.modelLabel));
        }
        return header;
    }

    // SVG chevron used as the trailing affordance on every status
    // pill. Pointing down mirrors the SwiftUI collapsed state
    // (chevron.up rotated 180°).
    var CHEVRON_DOWN_SVG =
        '<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" '
        + 'stroke-width="2" stroke-linecap="round" '
        + 'stroke-linejoin="round" aria-hidden="true">'
        + '<polyline points="2.5,4.5 6,8 9.5,4.5" />'
        + '</svg>';

    function appendChevron(pill) {
        var chev = makeEl("span", "pill-chevron");
        chev.innerHTML = CHEVRON_DOWN_SVG;
        pill.appendChild(chev);
    }

    function buildReasoningBanner(row) {
        if (!row.reasoning) return null;
        // Mirrors SwiftUI MessageReasoningProcessView's collapsed
        // header: purple dot + brain.fill + "Thought for …" +
        // disclosure chevron, wrapped in a purple-tinted pill.
        var banner = makeEl("div", "status-pill reasoning-pill");
        banner.appendChild(makeEl("span", "status-dot"));
        var icon = makeEl("span", "reasoning-icon");
        icon.innerHTML = symbolSVG("brain.fill");
        banner.appendChild(icon);
        banner.appendChild(
            makeEl("span", "pill-label", row.reasoning.durationLabel || "Thought")
        );
        appendChevron(banner);
        return banner;
    }

    function buildFunctionCalls(row) {
        if (!row.functionCalls || !row.functionCalls.length) return null;
        var wrap = makeEl("div", "function-calls");
        row.functionCalls.forEach(function (call) {
            // Mirrors SwiftUI FunctionCallView.label: colored dot
            // + "Function: <name>" (bold prefix, italic name) +
            // disclosure chevron when the call has executed.
            var rawStatus = (call.status || "succeeded").toLowerCase();
            var status = (rawStatus === "succeeded" || rawStatus === "failed" || rawStatus === "executing")
                ? rawStatus
                : "succeeded";
            var pill = makeEl("div", "status-pill fn-pill status-" + status);
            pill.appendChild(makeEl("span", "status-dot"));
            var label = makeEl("span", "pill-label");
            label.appendChild(makeEl("span", "fn-prefix", "Function: "));
            label.appendChild(makeEl("span", "fn-name", call.name || "function"));
            pill.appendChild(label);
            // Skip the chevron while the call is still in flight —
            // SwiftUI only shows it once the function has executed.
            if (call.didExecute !== false) {
                appendChevron(pill);
            }
            wrap.appendChild(pill);
        });
        return wrap;
    }

    function buildChipRow(items, options) {
        if (!items || !items.length) return null;
        var row = makeEl("div", "chip-row" + (options && options.extraClass ? " " + options.extraClass : ""));
        if (options && options.title) {
            row.appendChild(makeEl("div", "chip-section-title", options.title));
        }
        items.forEach(function (it) {
            var chip = makeEl("span", "chip");
            var symbolName = it.isWeb ? "globe" : "document";
            var iconWrap = makeEl("span", "chip-icon");
            iconWrap.innerHTML = symbolSVG(symbolName);
            chip.appendChild(iconWrap.firstChild);
            chip.appendChild(makeEl("span", "chip-label", it.filename || ""));
            row.appendChild(chip);
        });
        return row;
    }

    function buildMessageBody(row) {
        if (row.imageUrl) {
            var fig = makeEl("figure", "message-image");
            var img = document.createElement("img");
            img.src = row.imageUrl;
            img.alt = row.imageAlt || "Generated image";
            fig.appendChild(img);
            if (row.imageCaption) {
                fig.appendChild(makeEl("figcaption", null, row.imageCaption));
            }
            return fig;
        }
        var text = makeEl("div", "message-text markdown-body");
        var src = row.text || "";
        text.innerHTML = md.render(src);
        decorateText(text);
        return text;
    }

    function buildRow(row) {
        var rowEl = makeEl("div", "message-row");
        rowEl.appendChild(buildAvatar(row));
        var col = makeEl("div", "message-column");
        col.appendChild(buildHeader(row));

        var bubble = makeEl("div", "message-bubble");
        // Order matches SwiftUI MessageContentView: function calls
        // first, then the reasoning banner, then the response text.
        var fns = buildFunctionCalls(row);
        if (fns) bubble.appendChild(fns);
        var reasoning = buildReasoningBanner(row);
        if (reasoning) bubble.appendChild(reasoning);

        var body = buildMessageBody(row);
        bubble.appendChild(body);

        if (row.attachments && row.attachments.length) {
            var attachments = buildChipRow(row.attachments, {
                extraClass: "attachments"
            });
            if (attachments) bubble.appendChild(attachments);
        }
        if (row.references && row.references.length) {
            var references = buildChipRow(row.references, {
                title: "References",
                extraClass: "references"
            });
            if (references) bubble.appendChild(references);
        }

        col.appendChild(bubble);
        rowEl.appendChild(col);
        return rowEl;
    }

    // ---- Code highlighting + math + code chrome ------------------------

    function decorateText(node) {
        applyHighlight(node);
        applyMath(node);
        applyCodeChrome(node);
    }

    function applyHighlight(node) {
        if (!window.hljs) return;
        var blocks = node.querySelectorAll("pre code");
        for (var i = 0; i < blocks.length; i++) {
            var el = blocks[i];
            try {
                if (el.className && el.className.indexOf("language-") !== -1) {
                    window.hljs.highlightElement(el);
                } else {
                    var res = window.hljs.highlightAuto(el.textContent || "");
                    el.innerHTML = res.value;
                    if (res && res.language) {
                        el.classList.add("hljs", "language-" + res.language);
                    }
                }
            } catch (_) {
                // leave as plain text
            }
        }
    }

    function applyMath(node) {
        if (!window.renderMathInElement) return;
        try {
            window.renderMathInElement(node, {
                delimiters: [
                    { left: "$$", right: "$$", display: true },
                    { left: "\\[", right: "\\]", display: true },
                    { left: "\\(", right: "\\)", display: false },
                    { left: "$",  right: "$",  display: false },
                ],
                throwOnError: false,
                strict: false,
            });
        } catch (_) { /* noop */ }
    }

    function applyCodeChrome(node) {
        var pres = node.querySelectorAll("pre");
        for (var i = 0; i < pres.length; i++) {
            var pre = pres[i];
            if (pre.closest && pre.closest(".sk-codeblock")) continue;
            var codeEl = pre.querySelector("code");
            if (!codeEl) continue;

            var wrap = makeEl("div", "sk-codeblock");
            var header = makeEl("div", "sk-codeblock-header");
            header.appendChild(
                makeEl("span", "sk-codeblock-lang", detectLanguageName(codeEl))
            );
            header.appendChild(makeEl("div", "sk-codeblock-actions"));
            var body = makeEl("div", "sk-codeblock-body");
            pre.parentNode.insertBefore(wrap, pre);
            wrap.appendChild(header);
            wrap.appendChild(body);
            body.appendChild(pre);
        }
    }

    var LANG_LABELS = {
        js: "JavaScript", javascript: "JavaScript", jsx: "JavaScript (JSX)",
        ts: "TypeScript", typescript: "TypeScript", tsx: "TypeScript (TSX)",
        py: "Python", python: "Python", rb: "Ruby", ruby: "Ruby",
        rs: "Rust", rust: "Rust", go: "Go", golang: "Go", java: "Java",
        kt: "Kotlin", kotlin: "Kotlin", swift: "Swift", objc: "Objective-C",
        objectivec: "Objective-C", c: "C", cpp: "C++", "c++": "C++",
        cs: "C#", csharp: "C#", sh: "Shell", bash: "Bash", zsh: "Zsh",
        ps1: "PowerShell", powershell: "PowerShell", sql: "SQL", html: "HTML",
        css: "CSS", scss: "SCSS", less: "Less", xml: "XML", json: "JSON",
        jsonc: "JSON", yaml: "YAML", yml: "YAML", toml: "TOML",
        md: "Markdown", markdown: "Markdown", tex: "LaTeX", latex: "LaTeX",
        diff: "Diff", dockerfile: "Dockerfile", makefile: "Makefile",
        ini: "INI", graphql: "GraphQL", scala: "Scala", dart: "Dart",
        php: "PHP", lua: "Lua", r: "R", elixir: "Elixir", erlang: "Erlang",
        haskell: "Haskell", ocaml: "OCaml", perl: "Perl",
        plaintext: "Plain text", text: "Plain text", txt: "Plain text"
    };

    function detectLanguageName(codeEl) {
        var classes = (codeEl.className || "").split(/\s+/);
        for (var i = 0; i < classes.length; i++) {
            var c = classes[i];
            if (c.indexOf("language-") === 0) {
                var key = c.slice("language-".length).toLowerCase();
                if (LANG_LABELS[key]) return LANG_LABELS[key];
                return key.charAt(0).toUpperCase() + key.slice(1);
            }
        }
        return "Plain text";
    }

    // ---- Render + signal -----------------------------------------------

    function applyTheme(payload) {
        var bodyEl = document.body;
        bodyEl.classList.toggle("theme-dark", payload.theme === "dark");
        bodyEl.classList.toggle("theme-light", payload.theme !== "dark");

        var lightLink = document.getElementById("hljs-theme-light");
        var darkLink = document.getElementById("hljs-theme-dark");
        if (lightLink) lightLink.disabled = (payload.theme === "dark");
        if (darkLink)  darkLink.disabled  = (payload.theme !== "dark");

        if (payload.fontSize) {
            document.documentElement.style.setProperty(
                "--md-font-size",
                Math.max(8, +payload.fontSize) + "px"
            );
        }

        var tsEl = document.querySelector(".screenshot-ts");
        if (tsEl) tsEl.textContent = payload.timeLabel || "";
    }

    function renderAll(payload) {
        root = document.getElementById("root");
        root.setAttribute("data-row-count", String((payload.rows || []).length));
        var rows = (payload.rows || []).map(buildRow);
        for (var i = 0; i < rows.length; i++) {
            root.appendChild(rows[i]);
        }
    }

    function collectImages() {
        return Array.prototype.slice.call(document.querySelectorAll("img"));
    }

    // Wait until every <img> has finished loading (or definitively
    // failed). Uses img.decode() when available so the bitmap is
    // ready for compositing — without this the snapshot can capture
    // blank squares where images haven't painted yet.
    function awaitImages(timeoutMs) {
        var images = collectImages();
        if (images.length === 0) return Promise.resolve();
        var perImage = images.map(function (img) {
            if (img.complete && img.naturalWidth > 0 && img.decode) {
                return img.decode().catch(function () {});
            }
            return new Promise(function (resolve) {
                var done = false;
                function finish() {
                    if (done) return;
                    done = true;
                    if (img.decode) {
                        img.decode().catch(function () {}).then(resolve, resolve);
                    } else {
                        resolve();
                    }
                }
                img.addEventListener("load", finish);
                img.addEventListener("error", finish);
                // Hard timeout per image so a missing asset doesn't
                // block the whole snapshot.
                setTimeout(finish, timeoutMs || 8000);
            });
        });
        return Promise.all(perImage);
    }

    function awaitFonts() {
        if (document.fonts && document.fonts.ready) {
            return document.fonts.ready.catch(function () {});
        }
        return Promise.resolve();
    }

    function reportHeight() {
        if (!hostHeight) return;
        // The body wraps both #root and the footer; using body's
        // scrollHeight ensures both are included.
        var h = Math.ceil(document.body.scrollHeight);
        try { hostHeight.postMessage({ height: h }); } catch (_) {}
    }

    function signalReady() {
        if (!hostReady) return;
        try { hostReady.postMessage({ ready: true }); } catch (_) {}
    }

    function bootstrap(payload) {
        if (booted) return;
        booted = true;
        try {
            applyTheme(payload);
            renderAll(payload);
        } catch (err) {
            reportError((err && err.message) || String(err), "bootstrap");
            // Still signal ready so the host can fail fast rather
            // than waiting on the timeout.
            signalReady();
            return;
        }
        signalReady();
        // Wait for fonts + images to be ready before reporting the
        // final stable height. The renderer waits on this exact
        // height message before snapshotting.
        Promise.all([awaitFonts(), awaitImages()]).then(function () {
            // Two animation frames so any KaTeX layout shift settles
            // before we measure.
            requestAnimationFrame(function () {
                requestAnimationFrame(reportHeight);
            });
        }).catch(function (err) {
            reportError((err && err.message) || String(err), "await-loop");
            reportHeight();
        });
    }

    // Public entrypoint invoked by the host once the page is loaded.
    window.skBootstrap = function (payload) {
        var p = payload || window.skScreenshotPayload || { rows: [] };
        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", function () {
                bootstrap(p);
            });
        } else {
            bootstrap(p);
        }
    };

    // If the payload was injected before this script ran, kick off
    // automatically.
    if (window.skScreenshotPayload) {
        window.skBootstrap(window.skScreenshotPayload);
    }
})();
