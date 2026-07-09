// ============================================================================
//  Claude Desktop RTL — renderer payload
//
//  Detects right-to-left text (Hebrew, Arabic, Persian, Urdu, ...) in the
//  Claude Desktop UI and applies the correct direction and alignment to it in
//  real time, while keeping code blocks and math expressions left-to-right.
//  patch.sh prepends this file to the app's renderer/preload bundles.
//
//  Implementation notes:
//    * Self-contained IIFE; bails out where there is no DOM, so it is safe to
//      prepend to any bundle (including ones that never touch a document).
//    * Direction is decided from the first strong-directional character of an
//      element's visible text (ignoring code, URLs and file paths), which is
//      the standard Unicode-bidi heuristic.
//    * A MutationObserver keeps up with streamed responses; an input listener
//      keeps up with the composer as you type.
//    * The RTL font is NOT set here — patch.sh's font injector owns that so the
//      family name has a single source of truth.
//
//  Do not remove the START/END markers: patch.sh greps for them to avoid
//  double-patching a file.
// ============================================================================

// --- CLAUDE RTL PATCH START ---
(function () {
  "use strict";
  if (typeof document === "undefined") return;

  // Unicode blocks written right-to-left.
  var RTL_RANGES = [
    [0x0590, 0x05ff], // Hebrew
    [0x0600, 0x06ff], // Arabic
    [0x0700, 0x074f], // Syriac
    [0x0750, 0x077f], // Arabic Supplement
    [0x0780, 0x07bf], // Thaana
    [0x08a0, 0x08ff], // Arabic Extended-A
    [0xfb1d, 0xfdff], // Hebrew + Arabic presentation forms A
    [0xfe70, 0xfeff]  // Arabic presentation forms B
  ];

  // Markdown block elements whose own text we align.
  var BLOCK_SEL =
    "p, li, ul, ol, h1, h2, h3, h4, h5, h6, blockquote, td, th, dd, dt, " +
    "summary, figcaption, caption";
  // The message composer (contenteditable / textarea), across Claude versions.
  var INPUT_SEL = '[data-testid="chat-input"], [contenteditable="true"], textarea';
  // Always kept LTR.
  var CODE_SEL = "pre, code, kbd, samp, .code-block__code";
  var MATH_SEL =
    ".katex, .katex-display, mjx-container, math, .math, .math-inline, .math-display";

  function inRtlRange(cp) {
    for (var i = 0; i < RTL_RANGES.length; i++) {
      if (cp >= RTL_RANGES[i][0] && cp <= RTL_RANGES[i][1]) return true;
    }
    return false;
  }

  function hasRtl(text) {
    if (!text) return false;
    for (var i = 0; i < text.length; i++) {
      if (inRtlRange(text.charCodeAt(i))) return true;
    }
    return false;
  }

  function isLatin(cp) {
    return (cp >= 0x41 && cp <= 0x5a) || (cp >= 0x61 && cp <= 0x7a);
  }

  // Direction of the first strong-directional character. Neutrals (digits,
  // punctuation, spaces, symbols) are skipped, so a leading "1. " or "- " does
  // not force LTR on an otherwise RTL line.
  function firstStrong(text) {
    for (var i = 0; i < text.length; i++) {
      var cp = text.charCodeAt(i);
      if (inRtlRange(cp)) return "rtl";
      if (isLatin(cp)) return "ltr";
    }
    return null;
  }

  // Drop leading fragments whose Latin letters would give a false "ltr":
  // inline code, URLs and file paths.
  function withoutLtrTraps(text) {
    return text
      .replace(/`[^`]*`/g, " ")
      .replace(/https?:\/\/\S+/gi, " ")
      .replace(/[A-Za-z0-9._-]+[\/\\][A-Za-z0-9._\/\\-]+/g, " ");
  }

  // An element's visible text, ignoring code descendants.
  function textOutsideCode(el) {
    var out = "";
    for (var n = el.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3) {
        out += n.nodeValue;
      } else if (n.nodeType === 1) {
        var tag = n.tagName;
        if (tag !== "CODE" && tag !== "PRE" && tag !== "KBD" && tag !== "SAMP") {
          out += textOutsideCode(n);
        }
      }
    }
    return out;
  }

  // "rtl" if the element should be right-to-left, else null (leave default).
  function directionFor(el) {
    if (!hasRtl(el.textContent || "")) return null;
    var text = textOutsideCode(el);
    if (firstStrong(text) === "rtl") return "rtl";
    if (hasRtl(withoutLtrTraps(text))) return "rtl";
    return null;
  }

  function queryAll(root, sel) {
    var base = root && root.querySelectorAll ? root : document;
    var list = Array.prototype.slice.call(base.querySelectorAll(sel));
    if (root && root.nodeType === 1 && root.matches && root.matches(sel)) {
      list.unshift(root);
    }
    return list;
  }

  function within(el, sel) {
    return !!(el && el.closest && el.closest(sel));
  }

  function setDir(el, dir) {
    if (dir) {
      if (el.getAttribute("dir") !== dir) el.setAttribute("dir", dir);
    } else if (el.hasAttribute("dir")) {
      el.removeAttribute("dir");
    }
  }

  function alignBlocks(root) {
    var els = queryAll(root, BLOCK_SEL);
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (within(el, INPUT_SEL) || within(el, "pre") || within(el, "code")) continue;
      setDir(el, directionFor(el));
    }
  }

  function pinLtr(root, sel) {
    var els = queryAll(root, sel);
    for (var i = 0; i < els.length; i++) els[i].setAttribute("dir", "ltr");
  }

  // The composer needs the dir ATTRIBUTE (not just direction:style) so the
  // [dir='rtl'] font rule reaches it too, matching the responses.
  function alignComposer() {
    var inputs = queryAll(document, INPUT_SEL);
    for (var i = 0; i < inputs.length; i++) {
      var el = inputs[i];
      var text = el.value != null ? el.value : el.textContent || "";
      var dir = hasRtl(text) ? firstStrong(text) || "rtl" : "ltr";
      el.setAttribute("dir", dir);
      el.style.textAlign = dir === "rtl" ? "right" : "";
    }
  }

  function process(root) {
    root = root || document.body || document.documentElement;
    if (!root) return;
    alignBlocks(root);
    pinLtr(root, CODE_SEL);
    pinLtr(root, MATH_SEL);
    alignComposer();
  }

  function injectBaseStyles() {
    if (document.getElementById("claude-rtl-base")) return;
    var head = document.head || document.documentElement;
    if (!head) return;
    var unmarked = BLOCK_SEL.split(", ")
      .map(function (s) { return s + ":not([dir])"; })
      .join(",");
    var css =
      unmarked + "{unicode-bidi:plaintext;text-align:start}" +
      "[dir='rtl']{direction:rtl;text-align:start}" +
      "[dir='ltr']{direction:ltr;text-align:start}" +
      CODE_SEL + "{direction:ltr!important;unicode-bidi:isolate!important;text-align:left}" +
      MATH_SEL + "{direction:ltr!important;unicode-bidi:isolate!important}";
    var style = document.createElement("style");
    style.id = "claude-rtl-base";
    style.textContent = css;
    head.appendChild(style);
  }

  // Debounced batch of changed subtrees from the observer.
  var timer = null;
  var dirty = [];
  function schedule(node) {
    dirty.push(node);
    if (timer) return;
    timer = setTimeout(function () {
      timer = null;
      var roots = dirty;
      dirty = [];
      if (roots.length > 25) {
        process(document.body);
        return;
      }
      for (var i = 0; i < roots.length; i++) process(roots[i]);
    }, 50);
  }

  function start() {
    injectBaseStyles();
    process(document.body);
    if (!document.body) return;

    document.addEventListener(
      "input",
      function (e) {
        var t = e.target;
        if (t && (t.isContentEditable || t.tagName === "TEXTAREA" || t.tagName === "INPUT")) {
          alignComposer();
        }
      },
      true
    );

    new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var m = mutations[i];
        if (m.type === "characterData") {
          if (m.target.parentElement) schedule(m.target.parentElement);
        } else {
          for (var j = 0; j < m.addedNodes.length; j++) {
            if (m.addedNodes[j].nodeType === 1) schedule(m.addedNodes[j]);
          }
        }
      }
    }).observe(document.body, { childList: true, subtree: true, characterData: true });
  }

  function init() {
    try {
      start();
    } catch (e) {
      if (window.console && console.error) console.error("[Claude RTL]", e);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
// --- CLAUDE RTL PATCH END ---
