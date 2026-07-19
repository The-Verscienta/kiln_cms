/*!
 * Kiln visual-editing bridge (#355) — https://github.com/The-Verscienta/kiln_cms
 *
 * A dependency-free overlay an EXTERNAL headless front end embeds to get
 * in-context editing against a Kiln CMS. It:
 *
 *   1. decodes the invisible stega field-mapping Kiln bakes into the annotated
 *      preview (`GET /api/visual-editing/:type/:slug`) — or reads explicit
 *      `data-kiln-*` attributes the front end sets — to learn which Kiln field a
 *      rendered value came from;
 *   2. in edit mode, outlines editable regions and, on click, deep-links to the
 *      Kiln editor focused on that field (`/editor/site/:type/:slug?focus=<block>`);
 *   3. optionally opens a live-preview WebSocket (`/ws/bridge`) so the page can
 *      re-fetch and re-render when an editor changes the content in Kiln.
 *
 * Structural note: Kiln renders its own site with native in-context editing;
 * this bridge exists only because Kiln does NOT render an external front end, so
 * that front end must opt in (load this script; render the annotated preview in
 * edit mode). See docs/visual-editing-bridge.md.
 *
 * Usage:
 *   <script src="https://cms.example.com/bridge.js"
 *           data-kiln-host="https://cms.example.com"
 *           data-kiln-api-key="kiln_…"        // for live push + annotated fetch
 *           data-kiln-auto></script>
 */
(function () {
  "use strict";

  var TAG_BASE = 0xe0000;
  var TAG_START = 0xe0002;
  var TAG_STOP = 0xe007f;

  // ---- config -------------------------------------------------------------

  function currentScript() {
    return (
      document.currentScript ||
      (function () {
        var s = document.getElementsByTagName("script");
        return s[s.length - 1];
      })()
    );
  }

  var script = currentScript();
  var config = {
    host: attr(script, "data-kiln-host") || origin(script && script.src) || "",
    apiKey: attr(script, "data-kiln-api-key") || null,
  };

  function attr(el, name) {
    return el && el.getAttribute ? el.getAttribute(name) : null;
  }
  function origin(url) {
    try {
      return new URL(url).origin;
    } catch (e) {
      return "";
    }
  }

  // ---- stega decode (mirrors KilnCMS.VisualEditing.Stega) ------------------

  function decodeStega(text) {
    if (!text || text.indexOf(String.fromCodePoint(TAG_START)) === -1) return null;
    var collecting = false;
    var chars = "";
    for (var i = 0; i < text.length; ) {
      var cp = text.codePointAt(i);
      i += cp > 0xffff ? 2 : 1;
      if (!collecting) {
        if (cp === TAG_START) collecting = true;
        continue;
      }
      if (cp === TAG_STOP) break;
      chars += String.fromCharCode(cp - TAG_BASE);
    }
    if (!chars) return null;
    try {
      var b64 = chars.replace(/-/g, "+").replace(/_/g, "/");
      while (b64.length % 4) b64 += "=";
      return JSON.parse(decodeURIComponent(escape(atob(b64))));
    } catch (e) {
      return null;
    }
  }

  // Strip stega so a value can be shown/edited cleanly.
  function clean(text) {
    if (!text) return text;
    var out = "";
    for (var i = 0; i < text.length; ) {
      var cp = text.codePointAt(i);
      var w = cp > 0xffff ? 2 : 1;
      if (cp < TAG_BASE || cp > TAG_BASE + 0x7f) out += text.substr(i, w);
      i += w;
    }
    return out;
  }

  // ---- resolve an element to a Kiln field ---------------------------------

  // Explicit `data-kiln-*` attributes take precedence; otherwise decode stega
  // from the element's own text.
  function resolve(el) {
    if (!el || !el.getAttribute) return null;
    var field = el.getAttribute("data-kiln-field");
    if (field) {
      return {
        type: el.getAttribute("data-kiln-type"),
        id: el.getAttribute("data-kiln-id"),
        slug: el.getAttribute("data-kiln-slug"),
        field: field,
        block: el.getAttribute("data-kiln-block") || null,
      };
    }
    return decodeStega(el.textContent);
  }

  // Walk up from a node to the nearest element Kiln can address.
  function editableFrom(node) {
    var el = node && node.nodeType === 3 ? node.parentElement : node;
    while (el && el !== document.body) {
      var payload = resolve(el);
      if (payload && payload.type && payload.slug) return { el: el, payload: payload };
      el = el.parentElement;
    }
    return null;
  }

  // ---- overlay + edit mode ------------------------------------------------

  var enabled = false;
  var overlay = null;
  var updateCallbacks = [];

  function ensureOverlay() {
    if (overlay) return overlay;
    overlay = document.createElement("div");
    overlay.setAttribute("data-kiln-overlay", "");
    var s = overlay.style;
    s.position = "fixed";
    s.zIndex = "2147483000";
    s.pointerEvents = "none";
    s.border = "2px solid #4f46e5";
    s.borderRadius = "4px";
    s.background = "rgba(79,70,229,0.08)";
    s.transition = "all 60ms ease-out";
    s.display = "none";
    document.body.appendChild(overlay);
    return overlay;
  }

  function moveOverlay(el) {
    var o = ensureOverlay();
    var r = el.getBoundingClientRect();
    o.style.display = "block";
    o.style.top = r.top - 2 + "px";
    o.style.left = r.left - 2 + "px";
    o.style.width = r.width + "px";
    o.style.height = r.height + "px";
  }
  function hideOverlay() {
    if (overlay) overlay.style.display = "none";
  }

  var hovered = null;

  function onMove(e) {
    var hit = editableFrom(e.target);
    hovered = hit;
    if (hit) {
      moveOverlay(hit.el);
      document.body.style.cursor = "pointer";
    } else {
      hideOverlay();
      document.body.style.cursor = "";
    }
  }

  function onClick(e) {
    var hit = editableFrom(e.target);
    if (!hit) return;
    e.preventDefault();
    e.stopPropagation();
    openEditor(hit.payload);
  }

  function openEditor(p) {
    if (!config.host) return;
    var url =
      config.host.replace(/\/$/, "") +
      "/editor/site/" +
      encodeURIComponent(p.type) +
      "/" +
      encodeURIComponent(p.slug);
    if (p.block) url += "?focus=" + encodeURIComponent(p.block);
    // In a Kiln Presentation-style parent frame, hand off via postMessage;
    // otherwise open the editor directly.
    if (window.parent && window.parent !== window) {
      window.parent.postMessage({ source: "kiln-bridge", event: "edit", payload: p, url: url }, "*");
    } else {
      window.open(url, "kiln-editor");
    }
  }

  function enable() {
    if (enabled) return api;
    enabled = true;
    document.addEventListener("mousemove", onMove, true);
    document.addEventListener("click", onClick, true);
    document.documentElement.setAttribute("data-kiln-editing", "");
    return api;
  }

  function disable() {
    enabled = false;
    document.removeEventListener("mousemove", onMove, true);
    document.removeEventListener("click", onClick, true);
    document.documentElement.removeAttribute("data-kiln-editing");
    hideOverlay();
    document.body.style.cursor = "";
    return api;
  }

  // ---- live preview push (optional) ---------------------------------------

  var socket = null;

  function connect(type, id) {
    if (!config.host || !type || !id) return api;
    var base = config.host.replace(/^http/, "ws").replace(/\/$/, "");
    var url = base + "/ws/bridge?type=" + encodeURIComponent(type) + "&id=" + encodeURIComponent(id);
    if (config.apiKey) url += "&api_key=" + encodeURIComponent(config.apiKey);
    try {
      socket = new WebSocket(url);
      socket.onmessage = function (ev) {
        var msg;
        try {
          msg = JSON.parse(ev.data);
        } catch (e) {
          return;
        }
        if (msg && msg.event === "update") {
          updateCallbacks.forEach(function (cb) {
            try {
              cb(msg);
            } catch (e) {
              /* callback errors are the front end's problem */
            }
          });
        }
      };
    } catch (e) {
      /* live push is best-effort */
    }
    return api;
  }

  // Fetch the annotated preview JSON for a document (draft-visible with the key).
  function fetchPreview(type, slug) {
    var url =
      config.host.replace(/\/$/, "") +
      "/api/visual-editing/" +
      encodeURIComponent(type) +
      "/" +
      encodeURIComponent(slug);
    var headers = {};
    if (config.apiKey) headers["authorization"] = "Bearer " + config.apiKey;
    return fetch(url, { headers: headers, credentials: "omit" }).then(function (r) {
      return r.ok ? r.json() : Promise.reject(r.status);
    });
  }

  // ---- public API ---------------------------------------------------------

  var api = {
    version: "1",
    configure: function (opts) {
      if (opts && opts.host) config.host = opts.host;
      if (opts && opts.apiKey) config.apiKey = opts.apiKey;
      return api;
    },
    enable: enable,
    disable: disable,
    onUpdate: function (cb) {
      if (typeof cb === "function") updateCallbacks.push(cb);
      return api;
    },
    connect: connect,
    fetchPreview: fetchPreview,
    decode: decodeStega,
    clean: clean,
  };

  // When embedded in the Kiln Presentation console (#355), the parent nudges us
  // to refresh after a Kiln-side save: re-fetch via the registered onUpdate
  // callbacks if the front end wired them, else fall back to a full reload.
  window.addEventListener("message", function (e) {
    var d = e.data;
    if (!d || d.source !== "kiln-console" || d.event !== "refresh") return;
    if (updateCallbacks.length) {
      updateCallbacks.forEach(function (cb) {
        try {
          cb({ event: "refresh" });
        } catch (err) {
          /* front end's problem */
        }
      });
    } else {
      window.location.reload();
    }
  });

  window.KilnBridge = api;

  if (script && script.hasAttribute("data-kiln-auto")) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", enable);
    } else {
      enable();
    }
  }
})();
