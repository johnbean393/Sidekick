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

    // Incremental-parse bookkeeping. While streaming, we only parse the
    // tail of `text` past `settledLineCount`: every line before it is
    // already represented by a "settled" entry in `prevBlocks` whose
    // source can never change again. This keeps per-token work O(slice)
    // rather than O(text).
    var settledLineCount = 0;

    // Which rendering strategy currently owns the DOM:
    //   "idle":        nothing has been rendered yet.
    //   "incremental": block-by-block tree built up during streaming.
    //   "full":        single unified render produced from md.render(text)
    //                  once streaming has finished.
    var renderMode = "idle";

    // Cache of the most recent `text` rendered in full mode so a no-op
    // setStreaming(false) re-entry doesn't pay for another full re-render.
    var lastFullRenderedText = null;

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

    // Dispatch entry-point. Two distinct rendering paths:
    //   - while streaming, we use the *incremental* path that only
    //     re-parses the tail of `text` past the settled boundary.
    //   - once streaming has finished, we tear that scaffolding down
    //     and produce a single unified render via `md.render(text)` so
    //     the message reads as one cohesive block and the user can
    //     select / copy the whole thing without artificial seams.
    function performRender() {
        renderRunning = true;
        try {
            if (streaming) {
                if (renderMode === "full") {
                    // We were displaying a finished message and just got
                    // told we're streaming again — drop the unified DOM
                    // and start a fresh incremental tree.
                    resetIncrementalState();
                }
                renderMode = "incremental";
                renderIncremental();
            } else {
                if (renderMode === "full" && lastFullRenderedText === text) {
                    // No content change since the last full render —
                    // skip the costly innerHTML rebuild.
                    scheduleHeightReport();
                    return;
                }
                renderFull();
                renderMode = "full";
                lastFullRenderedText = text;
            }
        } finally {
            renderRunning = false;
        }
    }

    // Wipes the per-block scaffolding used by the incremental renderer.
    // Safe to call repeatedly — it's a no-op when the DOM is already
    // empty.
    function resetIncrementalState() {
        root.innerHTML = "";
        if (root.dataset) delete root.dataset.katex;
        prevBlocks.length = 0;
        settledLineCount = 0;
    }

    // Full re-render of the entire message — used on streaming end and
    // whenever a non-streaming caller pushes text. Produces a single
    // contiguous tree (no `.md-block` wrappers) so selection and copy
    // behave like an ordinary article.
    function renderFull() {
        // Drop any incremental bookkeeping; the unified DOM doesn't
        // need it and we want the next streaming session to start clean.
        prevBlocks.length = 0;
        settledLineCount = 0;
        if (root.dataset) delete root.dataset.katex;

        var source = text || "";
        // Single atomic innerHTML replacement — the browser swaps trees
        // in one shot, so the transition from incremental → full is
        // visually a single frame.
        root.innerHTML = source ? md.render(source) : "";

        if (source) {
            fullHighlightInside(root);
            renderMathInside(root);
        }

        scheduleHeightReport();
    }

    // Incremental render: re-parse only the slice of `text` past the
    // settled boundary, then update/extend the trailing block in place.
    // Promotes settled blocks (everything except the last group in the
    // slice) into the immutable prefix as soon as we see a new block
    // start after them.
    function renderIncremental() {
        var srcLines = text.split("\n");
        var sliceLines = srcLines.slice(settledLineCount);
        var sliceText = sliceLines.join("\n");

        if (sliceText.length === 0) {
            markTrailingBlock();
            scheduleHeightReport();
            return;
        }

        var env = {};
        var tokens = md.parse(sliceText, env);
        var groups = groupTopLevel(tokens);

        if (groups.length === 0) {
            markTrailingBlock();
            scheduleHeightReport();
            return;
        }

        // Pre-compute everything we need from each group up front.
        var parsed = [];
        for (var g = 0; g < groups.length; g++) {
            parsed.push({
                group: groups[g],
                source: groupSource(groups[g], tokens, sliceLines),
                type: classifyBlockType(tokens, groups[g]),
                html: renderTokensToHTML(tokens, groups[g], env)
            });
        }

        // Map the first group in the slice onto the currently-trailing
        // block (or create a fresh trailing block if there isn't one).
        var prevTrailing = prevBlocks.length > 0 ? prevBlocks[prevBlocks.length - 1] : null;
        var p0 = parsed[0];
        if (prevTrailing) {
            // Only swap the type class if it actually changed — overwriting
            // className would also drop md-trailing and re-fire the caret
            // animation each token.
            if (prevTrailing.type !== p0.type) {
                prevTrailing.node.classList.remove("md-" + prevTrailing.type);
                prevTrailing.node.classList.add("md-" + p0.type);
            }
            prevTrailing.node.classList.remove("md-new");
            prevTrailing.node.innerHTML = p0.html;
            // hljs's marker lives on the <code> elements (now replaced);
            // KaTeX's lives on the wrapper, so we have to clear it
            // explicitly to allow re-rendering if math arrived.
            if (prevTrailing.node.dataset) {
                delete prevTrailing.node.dataset.katex;
            }
            prevTrailing.source = p0.source;
            prevTrailing.type = p0.type;
            prevTrailing.fullyDecorated = false;
        } else {
            var firstNode = document.createElement("div");
            firstNode.className = "md-block md-" + p0.type + " md-new";
            firstNode.innerHTML = p0.html;
            root.appendChild(firstNode);
            prevBlocks.push({
                source: p0.source,
                type: p0.type,
                node: firstNode,
                fullyDecorated: false
            });
        }

        // No new blocks — we just grew the trailing block.
        if (parsed.length === 1) {
            markTrailingBlock();
            scheduleHeightReport();
            return;
        }

        // We saw at least one new block start past the old trailing,
        // which means the old trailing has finished. Decorate it once
        // now and treat it as settled.
        var justSettled = prevBlocks[prevBlocks.length - 1];
        if (!justSettled.fullyDecorated) {
            fullHighlightInside(justSettled.node);
            renderMathInside(justSettled.node);
            justSettled.fullyDecorated = true;
        }

        // Append intermediate, fully-closed blocks (everything between
        // the freshly-settled head and the new trailing tail).
        for (var i = 1; i < parsed.length - 1; i++) {
            var mid = parsed[i];
            var midNode = document.createElement("div");
            midNode.className = "md-block md-" + mid.type;
            midNode.innerHTML = mid.html;
            root.appendChild(midNode);
            var midBlock = {
                source: mid.source,
                type: mid.type,
                node: midNode,
                fullyDecorated: false
            };
            prevBlocks.push(midBlock);
            fullHighlightInside(midNode);
            renderMathInside(midNode);
            midBlock.fullyDecorated = true;
        }

        // Append the new trailing block.
        var last = parsed[parsed.length - 1];
        var lastNode = document.createElement("div");
        lastNode.className = "md-block md-" + last.type + " md-new";
        lastNode.innerHTML = last.html;
        root.appendChild(lastNode);
        prevBlocks.push({
            source: last.source,
            type: last.type,
            node: lastNode,
            fullyDecorated: false
        });

        // Advance the settled boundary: any line strictly before the new
        // trailing block's first line is now immutable. Use the token map
        // (relative to the slice) to find that line.
        var lastStartLine = Infinity;
        for (var k = last.group.start; k < last.group.end; k++) {
            var m = tokens[k].map;
            if (m && m[0] < lastStartLine) lastStartLine = m[0];
        }
        if (lastStartLine !== Infinity) {
            settledLineCount += lastStartLine;
        }

        markTrailingBlock();
        scheduleHeightReport();
    }

    // Idempotent: ensures only the last block carries `.md-trailing`
    // and that we don't restart the caret animation by toggling the
    // class needlessly on the same node.
    function markTrailingBlock() {
        if (prevBlocks.length === 0) return;
        for (var t = 0; t < prevBlocks.length - 1; t++) {
            prevBlocks[t].node.classList.remove("md-trailing");
        }
        var trailingNode = prevBlocks[prevBlocks.length - 1].node;
        if (!trailingNode.classList.contains("md-trailing")) {
            trailingNode.classList.add("md-trailing");
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

    // Inline SVGs used for the code-block action buttons. Stroke-based so
    // they inherit `currentColor` and stay crisp at any size. Sizes are
    // governed by the wrapping button via `width`/`height` properties on
    // `svg.sk-icon` (see chat.css).
    var ICONS = {
        // "Duplicate" glyph similar in spirit to SF Symbols' doc.on.doc.
        copy: ''
            + '<svg class="sk-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor"'
            + ' stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
            + '<rect x="5" y="5" width="8" height="9" rx="1.6"/>'
            + '<path d="M3.5 11V3.6A1.6 1.6 0 0 1 5.1 2H10"/>'
            + '</svg>',
        // Two arrows pointing apart — "expand".
        expand: ''
            + '<svg class="sk-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor"'
            + ' stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
            + '<path d="M9.5 2.5h4v4"/>'
            + '<path d="M13.5 2.5 9.2 6.8"/>'
            + '<path d="M6.5 13.5h-4v-4"/>'
            + '<path d="m2.5 13.5 4.3-4.3"/>'
            + '</svg>',
        // Two arrows pointing inward — "collapse".
        collapse: ''
            + '<svg class="sk-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor"'
            + ' stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
            + '<path d="M13.5 6.5h-4v-4"/>'
            + '<path d="M9.5 6.5 13.8 2.2"/>'
            + '<path d="M2.5 9.5h4v4"/>'
            + '<path d="m6.5 9.5-4.3 4.3"/>'
            + '</svg>',
        // Checkmark used as transient "copied" feedback.
        check: ''
            + '<svg class="sk-icon" viewBox="0 0 16 16" fill="none" stroke="currentColor"'
            + ' stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
            + '<path d="M3 8.5 6.4 12 13 5"/>'
            + '</svg>'
    };

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
                var expandTitle = "Show all " + lineCount + " lines";
                var collapseTitle = "Show less";
                toggleBtn.setAttribute("data-expand-title", expandTitle);
                toggleBtn.setAttribute("data-collapse-title", collapseTitle);
                toggleBtn.setAttribute("data-state", "collapsed");
                toggleBtn.setAttribute("title", expandTitle);
                toggleBtn.setAttribute("aria-label", expandTitle);
                toggleBtn.innerHTML = ICONS.expand;
                actions.appendChild(toggleBtn);
            }

            var copyBtn = document.createElement("button");
            copyBtn.type = "button";
            copyBtn.className = "sk-codeblock-copy";
            copyBtn.setAttribute("title", "Copy");
            copyBtn.setAttribute("aria-label", "Copy code");
            copyBtn.innerHTML = ICONS.copy;
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
        // Stash the original glyph so we can restore it after the
        // "copied" flash.
        if (!btn.dataset.originalHtml) {
            btn.dataset.originalHtml = btn.innerHTML;
        }
        btn.innerHTML = ICONS.check;
        btn.classList.add("sk-copied");
        btn.setAttribute("aria-label", "Copied");
        btn.setAttribute("title", "Copied");
        btn.__skCopyTimer = setTimeout(function () {
            btn.innerHTML = btn.dataset.originalHtml || ICONS.copy;
            btn.classList.remove("sk-copied");
            btn.setAttribute("aria-label", "Copy code");
            btn.setAttribute("title", "Copy");
            delete btn.dataset.originalHtml;
            btn.__skCopyTimer = null;
        }, 1100);
    }

    function handleToggleClick(btn) {
        var wrapper = btn.closest ? btn.closest(".sk-codeblock") : null;
        if (!wrapper) return;
        var wasCollapsed = wrapper.getAttribute("data-collapsed") === "true";
        if (wasCollapsed) {
            wrapper.removeAttribute("data-collapsed");
            var collapseTitle = btn.getAttribute("data-collapse-title") || "Show less";
            btn.setAttribute("data-state", "expanded");
            btn.setAttribute("title", collapseTitle);
            btn.setAttribute("aria-label", collapseTitle);
            btn.innerHTML = ICONS.collapse;
        } else {
            wrapper.setAttribute("data-collapsed", "true");
            var expandTitle = btn.getAttribute("data-expand-title") || "Show all";
            btn.setAttribute("data-state", "collapsed");
            btn.setAttribute("title", expandTitle);
            btn.setAttribute("aria-label", expandTitle);
            btn.innerHTML = ICONS.expand;
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
        if (root.dataset) delete root.dataset.katex;
        lastReportedHeight = -1;
        settledLineCount = 0;
        renderMode = "idle";
        lastFullRenderedText = null;
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
