/* Sidekick chat markdown renderer.
   - Streams Markdown into a per-message WKWebView.
   - Uses markdown-it for fast incremental parses.
   - Diffs at the top-level block granularity: a block whose source has not
     changed since the previous render keeps its DOM (and its highlight.js /
     KaTeX state) untouched. Only the trailing in-progress block re-renders
     per token.
   - Reports content height back to the host via webkit.messageHandlers. */

(function () {
    "use strict";

    var hostHeightHandler = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.heightChanged) || null;
    var hostReadyHandler = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ready) || null;
    var hostLinkHandler = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.openLink) || null;
    var hostCopyHandler = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.copyCode) || null;

    var md = window.markdownit({
        html: false,
        linkify: true,
        typographer: false,
        breaks: false,
    });

    // Make all links open through the host (Swift decides where to send them).
    var defaultLinkOpen = md.renderer.rules.link_open || function (tokens, idx, options, env, self) {
        return self.renderToken(tokens, idx, options);
    };
    md.renderer.rules.link_open = function (tokens, idx, options, env, self) {
        var token = tokens[idx];
        token.attrSet("target", "_blank");
        token.attrSet("rel", "noopener noreferrer");
        return defaultLinkOpen(tokens, idx, options, env, self);
    };

    // Rewrite image srcs so anything that isn't a network/data URL is
    // proxied through Swift via the sidekick-asset:// scheme. The Swift
    // side knows how to find file paths, generated images, etc.
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
        // Lazy-load images so they don't block initial layout for long
        // history conversations.
        token.attrSet("loading", "lazy");
        token.attrSet("decoding", "async");
        return defaultImageRule(tokens, idx, options, env, self);
    };

    var root = document.getElementById("root");
    var bodyEl = document.body;

    // State.
    var text = "";
    var streaming = false;
    var prevBlocks = []; // [{ source, type, node }]
    var renderScheduled = false;
    var renderRunning = false;
    var heightScheduled = false;
    var lastReportedHeight = -1;

    // ---- Block segmentation ----------------------------------------------

    // Walk a flat token stream and yield groups corresponding to top-level
    // blocks. A block is either a self-closing top-level token (fence, hr,
    // html_block, code_block) or an open/close pair with anything nested in
    // between.
    function groupTopLevel(tokens) {
        var groups = [];
        var depth = 0;
        var start = 0;
        for (var i = 0; i < tokens.length; i++) {
            var t = tokens[i];
            if (t.level !== 0) continue;
            if (t.nesting === 1) {
                if (depth === 0) start = i;
                depth++;
            } else if (t.nesting === -1) {
                depth--;
                if (depth === 0) {
                    groups.push({ start: start, end: i + 1 });
                }
            } else if (t.nesting === 0 && depth === 0) {
                groups.push({ start: i, end: i + 1 });
            }
        }
        // If the document is mid-block (depth > 0 at EOF, e.g. an unclosed
        // fence while streaming), emit the trailing partial as one block so
        // the user sees progress.
        if (depth > 0 && start < tokens.length) {
            groups.push({ start: start, end: tokens.length });
        }
        return groups;
    }

    // Compute the source text covered by a token group, using token.map.
    function groupSource(group, tokens, srcLines) {
        var first = null, last = null;
        for (var k = group.start; k < group.end; k++) {
            var m = tokens[k].map;
            if (!m) continue;
            if (first === null) first = m[0];
            last = m[1];
        }
        if (first === null) return "";
        if (last === null) last = first;
        return srcLines.slice(first, last).join("\n");
    }

    function classifyBlockType(tokens, group) {
        var first = tokens[group.start];
        if (!first) return "block";
        switch (first.type) {
            case "fence": return "fence";
            case "code_block": return "fence";
            case "heading_open": return "heading";
            case "paragraph_open": return "paragraph";
            case "bullet_list_open": return "list";
            case "ordered_list_open": return "list";
            case "blockquote_open": return "quote";
            case "table_open": return "table";
            case "hr": return "hr";
            case "html_block": return "html";
            case "math_block": return "math";
            default: return first.type || "block";
        }
    }

    // ---- Rendering -------------------------------------------------------

    function renderTokensToHTML(tokens, group, env) {
        // markdown-it's renderer accepts a sub-range via tokens.slice.
        return md.renderer.render(tokens.slice(group.start, group.end), md.options, env);
    }

    // Schedule a render on the next animation frame so back-to-back
    // appendMarkdown calls coalesce.
    function scheduleRender() {
        if (renderScheduled || renderRunning) return;
        renderScheduled = true;
        requestAnimationFrame(function () {
            renderScheduled = false;
            try { performRender(); } catch (err) {
                console.error("[sk] render failed", err);
            }
        });
    }

    function performRender() {
        renderRunning = true;
        try {
            var env = {};
            var tokens = md.parse(text, env);
            var groups = groupTopLevel(tokens);
            var srcLines = text.split("\n");

            // Build the new block list.
            var newBlocks = [];
            for (var g = 0; g < groups.length; g++) {
                var group = groups[g];
                var source = groupSource(group, tokens, srcLines);
                var type = classifyBlockType(tokens, group);
                newBlocks.push({ source: source, type: type, group: group });
            }

            // Find longest common prefix of unchanged blocks (compare by
            // source). During streaming this is almost the entire document
            // minus the trailing block.
            var commonLen = 0;
            var maxCommon = Math.min(newBlocks.length, prevBlocks.length);
            while (commonLen < maxCommon &&
                   newBlocks[commonLen].source === prevBlocks[commonLen].source) {
                commonLen++;
            }

            // Reuse the DOM node at index commonLen across renders when
            // possible. This is the streaming hot path: the trailing block
            // grows by a few characters per token and we want to update its
            // innerHTML in place instead of destroying and re-creating the
            // wrapper (which causes the .md-new fade-in to re-fire every
            // frame and produces visible flicker at the end of the message).
            var reuseStart = commonLen;
            var changedNodes = []; // wrappers we touched this render
            if (commonLen < newBlocks.length && commonLen < prevBlocks.length) {
                var oldBlock = prevBlocks[commonLen];
                var nextNewBlock = newBlocks[commonLen];
                var nextHtml = renderTokensToHTML(tokens, nextNewBlock.group, env);
                // Only mutate the *type* class if it actually changed —
                // overwriting className would yank md-trailing off the
                // element each render, restarting the caret CSS animation
                // and producing a visible jitter.
                if (oldBlock.type !== nextNewBlock.type) {
                    oldBlock.node.classList.remove("md-" + oldBlock.type);
                    oldBlock.node.classList.add("md-" + nextNewBlock.type);
                }
                // The md-new fade-in only ever applies to the first paint
                // of a freshly-created wrapper — drop it now so a reused
                // wrapper doesn't keep restarting its animation.
                oldBlock.node.classList.remove("md-new");
                oldBlock.node.innerHTML = nextHtml;
                // The wrapper is reused — clear KaTeX's "already rendered"
                // marker because the inner DOM was replaced. hljs's marker
                // lives on the <code> element so it's already gone.
                if (oldBlock.node.dataset) {
                    delete oldBlock.node.dataset.katex;
                }
                nextNewBlock.node = oldBlock.node;
                nextNewBlock.fullyDecorated = false;
                prevBlocks[commonLen] = nextNewBlock;
                changedNodes.push(nextNewBlock);
                reuseStart = commonLen + 1;
            }

            // Drop any old blocks past the reused range.
            while (prevBlocks.length > reuseStart) {
                var dead = prevBlocks.pop();
                if (dead.node && dead.node.parentNode) {
                    dead.node.parentNode.removeChild(dead.node);
                }
            }

            // Reset transient classes on the unchanged prefix (the old
            // trailing block, if any, is no longer trailing once we've
            // pushed something past it).
            for (var p = 0; p < commonLen; p++) {
                var pb = prevBlocks[p];
                pb.node.classList.remove("md-trailing", "md-new");
            }

            // Render and append the remaining new blocks. These are
            // genuinely new wrappers — they get .md-new so we fade them in.
            for (var k = reuseStart; k < newBlocks.length; k++) {
                var b = newBlocks[k];
                var html = renderTokensToHTML(tokens, b.group, env);
                var node = document.createElement("div");
                node.className = "md-block md-" + b.type + " md-new";
                node.innerHTML = html;
                root.appendChild(node);
                b.node = node;
                prevBlocks.push(b);
                changedNodes.push(b);
            }

            // Mark the trailing block (only meaningful when streaming).
            // We clear md-trailing from every non-last block first; we do
            // NOT touch the last block's classList if it already has the
            // class so we avoid restarting the caret animation each frame.
            if (prevBlocks.length > 0) {
                for (var t = 0; t < prevBlocks.length - 1; t++) {
                    prevBlocks[t].node.classList.remove("md-trailing");
                }
                var trailingNode = prevBlocks[prevBlocks.length - 1].node;
                if (!trailingNode.classList.contains("md-trailing")) {
                    trailingNode.classList.add("md-trailing");
                }
            }

            // Post-process the blocks we just touched.
            for (var n = 0; n < changedNodes.length; n++) {
                var pb2 = changedNodes[n];
                var isLast = (pb2 === prevBlocks[prevBlocks.length - 1]);
                // Don't fully highlight or KaTeX-render the trailing block
                // while still streaming — that block can mutate further.
                if (streaming && isLast) {
                    softHighlightInside(pb2.node);
                } else {
                    fullHighlightInside(pb2.node);
                    renderMathInside(pb2.node);
                }
            }

            // After a non-streaming render (or after a chunk that pushed a
            // brand new block past the previously-trailing one), make sure
            // older blocks are fully decorated. Anything in the prefix only
            // needs decoration if we hadn't fully processed it yet.
            if (!streaming) {
                for (var f = 0; f < prevBlocks.length; f++) {
                    var fb = prevBlocks[f];
                    if (!fb.fullyDecorated) {
                        fullHighlightInside(fb.node);
                        renderMathInside(fb.node);
                        fb.fullyDecorated = true;
                    }
                }
            } else {
                // Streaming: blocks that have moved out of trailing position
                // become "settled" — decorate them once.
                for (var f2 = 0; f2 < prevBlocks.length - 1; f2++) {
                    var fb2 = prevBlocks[f2];
                    if (!fb2.fullyDecorated) {
                        fullHighlightInside(fb2.node);
                        renderMathInside(fb2.node);
                        fb2.fullyDecorated = true;
                    }
                }
            }

            scheduleHeightReport();
        } finally {
            renderRunning = false;
        }
    }

    // ---- Code highlighting ----------------------------------------------

    function fullHighlightInside(node) {
        if (!window.hljs) {
            enhanceCodeBlocks(node);
            return;
        }
        var blocks = node.querySelectorAll("pre code");
        for (var i = 0; i < blocks.length; i++) {
            var el = blocks[i];
            if (el.dataset.hljs === "1") continue;
            var autoLang = null;
            try {
                if (el.className && el.className.indexOf("language-") !== -1) {
                    window.hljs.highlightElement(el);
                } else {
                    var res = window.hljs.highlightAuto(el.textContent || "");
                    el.innerHTML = res.value;
                    autoLang = res && res.language ? res.language : null;
                    if (autoLang) {
                        el.classList.add("hljs", "language-" + autoLang);
                    }
                }
                el.dataset.hljs = "1";
            } catch (_) {
                // Leave as plain text.
            }
        }
        enhanceCodeBlocks(node);
    }

    // While streaming, just mark the code as plain — we'll highlight when
    // the fence completes or the block stops being trailing.
    function softHighlightInside(node) {
        // Intentionally a no-op: leave incomplete code as plain text.
        // The "soft" flag is just for future hooks.
        void node;
    }

    // ---- Code block chrome ----------------------------------------------

    // Number of source lines at which a code block becomes collapsible.
    var COLLAPSE_THRESHOLD = 30;

    // Wrap each <pre> in a chrome container with a header (language label,
    // copy button, and — when the block is >= COLLAPSE_THRESHOLD lines —
    // an expand/collapse toggle). Idempotent: each <pre> is enhanced at
    // most once, gated by data-sk-enhanced.
    function enhanceCodeBlocks(scope) {
        if (!scope) return;
        var pres = scope.querySelectorAll("pre");
        for (var i = 0; i < pres.length; i++) {
            var pre = pres[i];
            if (pre.dataset.skEnhanced === "1") continue;
            if (pre.closest && pre.closest(".sk-codeblock")) {
                // Already wrapped by a prior enhancement (defensive).
                pre.dataset.skEnhanced = "1";
                continue;
            }
            var codeEl = pre.querySelector("code");
            if (!codeEl) continue;

            var langName = detectLanguageName(codeEl);
            var text = codeEl.textContent || "";
            var lineCount = countLines(text);
            var collapsible = lineCount >= COLLAPSE_THRESHOLD;

            var wrapper = document.createElement("div");
            wrapper.className = "sk-codeblock";
            if (collapsible) {
                wrapper.setAttribute("data-collapsed", "true");
            }

            var header = document.createElement("div");
            header.className = "sk-codeblock-header";

            var langSpan = document.createElement("span");
            langSpan.className = "sk-codeblock-lang";
            langSpan.textContent = langName;
            header.appendChild(langSpan);

            var actions = document.createElement("div");
            actions.className = "sk-codeblock-actions";

            if (collapsible) {
                var toggleBtn = document.createElement("button");
                toggleBtn.type = "button";
                toggleBtn.className = "sk-codeblock-toggle";
                toggleBtn.setAttribute("data-collapsed-label", "Show all " + lineCount + " lines");
                toggleBtn.setAttribute("data-expanded-label", "Show less");
                toggleBtn.textContent = "Show all " + lineCount + " lines";
                actions.appendChild(toggleBtn);
            }

            var copyBtn = document.createElement("button");
            copyBtn.type = "button";
            copyBtn.className = "sk-codeblock-copy";
            copyBtn.textContent = "Copy";
            actions.appendChild(copyBtn);

            header.appendChild(actions);

            var body = document.createElement("div");
            body.className = "sk-codeblock-body";

            // Insert wrapper in place of <pre>, then move <pre> inside.
            pre.parentNode.insertBefore(wrapper, pre);
            wrapper.appendChild(header);
            wrapper.appendChild(body);
            body.appendChild(pre);

            pre.dataset.skEnhanced = "1";
        }
    }

    // Map hljs language slugs to a friendlier label for the header.
    var LANG_LABELS = {
        js: "JavaScript",
        javascript: "JavaScript",
        jsx: "JavaScript (JSX)",
        ts: "TypeScript",
        typescript: "TypeScript",
        tsx: "TypeScript (TSX)",
        py: "Python",
        python: "Python",
        rb: "Ruby",
        ruby: "Ruby",
        rs: "Rust",
        rust: "Rust",
        go: "Go",
        golang: "Go",
        java: "Java",
        kt: "Kotlin",
        kotlin: "Kotlin",
        swift: "Swift",
        objc: "Objective-C",
        objectivec: "Objective-C",
        c: "C",
        cpp: "C++",
        "c++": "C++",
        cs: "C#",
        csharp: "C#",
        sh: "Shell",
        bash: "Bash",
        zsh: "Zsh",
        ps1: "PowerShell",
        powershell: "PowerShell",
        sql: "SQL",
        html: "HTML",
        css: "CSS",
        scss: "SCSS",
        less: "Less",
        xml: "XML",
        json: "JSON",
        jsonc: "JSON",
        yaml: "YAML",
        yml: "YAML",
        toml: "TOML",
        md: "Markdown",
        markdown: "Markdown",
        tex: "LaTeX",
        latex: "LaTeX",
        diff: "Diff",
        dockerfile: "Dockerfile",
        makefile: "Makefile",
        ini: "INI",
        graphql: "GraphQL",
        scala: "Scala",
        dart: "Dart",
        php: "PHP",
        lua: "Lua",
        r: "R",
        elixir: "Elixir",
        erlang: "Erlang",
        haskell: "Haskell",
        ocaml: "OCaml",
        perl: "Perl",
        plaintext: "Plain text",
        text: "Plain text",
        txt: "Plain text"
    };

    function detectLanguageName(codeEl) {
        var classes = (codeEl.className || "").split(/\s+/);
        for (var i = 0; i < classes.length; i++) {
            var c = classes[i];
            if (c.indexOf("language-") === 0) {
                return prettifyLanguage(c.slice("language-".length));
            }
        }
        return "Plain text";
    }

    function prettifyLanguage(raw) {
        if (!raw) return "Plain text";
        var key = raw.toLowerCase();
        if (LANG_LABELS[key]) return LANG_LABELS[key];
        // Fall back to a capitalised version of the raw slug.
        return raw.charAt(0).toUpperCase() + raw.slice(1);
    }

    function countLines(text) {
        if (!text) return 0;
        var n = 1;
        for (var i = 0; i < text.length; i++) {
            if (text.charCodeAt(i) === 10) n++;
        }
        // Strip a trailing newline so a 30-line file isn't reported as 31.
        if (text.length > 0 && text.charCodeAt(text.length - 1) === 10) {
            n = Math.max(1, n - 1);
        }
        return n;
    }

    function handleCopyClick(btn) {
        var wrapper = btn.closest ? btn.closest(".sk-codeblock") : null;
        if (!wrapper) return;
        var codeEl = wrapper.querySelector("pre code");
        var text = codeEl ? (codeEl.textContent || "") : "";
        if (hostCopyHandler) {
            try { hostCopyHandler.postMessage({ text: text }); } catch (_) {}
        } else if (navigator && navigator.clipboard && navigator.clipboard.writeText) {
            try { navigator.clipboard.writeText(text); } catch (_) {}
        }
        showCopyFeedback(btn);
    }

    function showCopyFeedback(btn) {
        if (btn.__skCopyTimer) clearTimeout(btn.__skCopyTimer);
        var original = btn.dataset.originalLabel || btn.textContent;
        btn.dataset.originalLabel = original;
        btn.textContent = "Copied";
        btn.classList.add("sk-copied");
        btn.__skCopyTimer = setTimeout(function () {
            btn.textContent = original;
            btn.classList.remove("sk-copied");
            btn.__skCopyTimer = null;
        }, 1100);
    }

    function handleToggleClick(btn) {
        var wrapper = btn.closest ? btn.closest(".sk-codeblock") : null;
        if (!wrapper) return;
        var wasCollapsed = wrapper.getAttribute("data-collapsed") === "true";
        if (wasCollapsed) {
            wrapper.removeAttribute("data-collapsed");
            btn.textContent = btn.getAttribute("data-expanded-label") || "Show less";
        } else {
            wrapper.setAttribute("data-collapsed", "true");
            btn.textContent = btn.getAttribute("data-collapsed-label") || "Show all";
        }
        scheduleHeightReport();
    }

    document.addEventListener("click", function (e) {
        var target = e.target;
        if (!target || !target.closest) return;
        var copyBtn = target.closest(".sk-codeblock-copy");
        if (copyBtn) {
            e.preventDefault();
            e.stopPropagation();
            handleCopyClick(copyBtn);
            return;
        }
        var toggleBtn = target.closest(".sk-codeblock-toggle");
        if (toggleBtn) {
            e.preventDefault();
            e.stopPropagation();
            handleToggleClick(toggleBtn);
            return;
        }
    }, true);

    // ---- Math rendering --------------------------------------------------

    function renderMathInside(node) {
        if (!window.renderMathInElement) return;
        if (node.dataset.katex === "1") return;
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
            node.dataset.katex = "1";
        } catch (_) {
            // Ignore — leave raw $...$ in place.
        }
    }

    // ---- Height reporting ------------------------------------------------

    function scheduleHeightReport() {
        if (heightScheduled || !hostHeightHandler) return;
        heightScheduled = true;
        requestAnimationFrame(function () {
            heightScheduled = false;
            reportHeight();
        });
    }

    function reportHeight() {
        if (!hostHeightHandler) return;
        // Use scrollHeight on body so margins are included.
        var rect = root.getBoundingClientRect();
        // Math.ceil to avoid sub-pixel clipping; scrollHeight ignores fractional pixels.
        var h = Math.ceil(rect.height);
        if (h === lastReportedHeight) return;
        lastReportedHeight = h;
        hostHeightHandler.postMessage({ height: h });
    }

    // ResizeObserver makes the layout settle automatically when fonts load
    // or async content (KaTeX) arrives.
    if (window.ResizeObserver) {
        var ro = new ResizeObserver(function () { scheduleHeightReport(); });
        ro.observe(root);
    } else {
        window.addEventListener("resize", scheduleHeightReport);
    }

    // ---- Link interception ----------------------------------------------

    document.addEventListener("click", function (e) {
        var t = e.target;
        while (t && t !== document.body && t.tagName !== "A") {
            t = t.parentNode;
        }
        if (!t || t.tagName !== "A") return;
        var href = t.getAttribute("href");
        if (!href) return;
        e.preventDefault();
        if (hostLinkHandler) {
            hostLinkHandler.postMessage({ href: href });
        }
    }, true);

    // ---- Public API ------------------------------------------------------

    function applyTheme(scheme) {
        var dark = scheme === "dark";
        bodyEl.classList.toggle("theme-dark", dark);
        bodyEl.classList.toggle("theme-light", !dark);
        var lightLink = document.getElementById("hljs-theme-light");
        var darkLink = document.getElementById("hljs-theme-dark");
        if (lightLink) lightLink.disabled = dark;
        if (darkLink)  darkLink.disabled  = !dark;
    }

    function applyFontSize(px) {
        document.documentElement.style.setProperty("--md-font-size", Math.max(8, +px) + "px");
    }

    function applyMode(mode) {
        // Known modes: "default", "reasoning".
        var safe = (mode === "reasoning") ? "reasoning" : "default";
        bodyEl.setAttribute("data-mode", safe);
    }

    function reset() {
        text = "";
        prevBlocks.length = 0;
        root.innerHTML = "";
        lastReportedHeight = -1;
    }

    window.sk = {
        setMarkdown: function (newText) {
            // If the new text starts with the old text, fast-path to append.
            if (typeof newText !== "string") newText = String(newText || "");
            if (newText === text) return;
            if (newText.length > text.length && newText.indexOf(text) === 0) {
                text = newText;
                scheduleRender();
                return;
            }
            // Otherwise it's a non-prefix change — wipe state and re-render.
            reset();
            text = newText;
            scheduleRender();
        },
        appendMarkdown: function (chunk) {
            if (!chunk) return;
            text += String(chunk);
            scheduleRender();
        },
        setStreaming: function (on) {
            streaming = !!on;
            bodyEl.setAttribute("data-streaming", streaming ? "true" : "false");
            scheduleRender();
        },
        setColorScheme: function (scheme) {
            applyTheme(scheme);
            scheduleHeightReport();
        },
        setFontSize: function (px) {
            applyFontSize(px);
            scheduleHeightReport();
        },
        setMode: function (mode) {
            applyMode(mode);
            scheduleHeightReport();
        },
        flush: function () {
            // Force a synchronous render — used by the host before tearing down.
            if (renderScheduled) {
                renderScheduled = false;
            }
            performRender();
        },
        reset: reset,
    };

    if (hostReadyHandler) {
        hostReadyHandler.postMessage({ ready: true });
    }
})();
