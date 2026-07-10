/*!
 * KilnCMS embeddable forms — host-page snippet.
 *
 * Drop this on any site to render a form served by your KilnCMS instance:
 *
 *   <script src="https://cms.example.com/embed.js" data-kiln-form="contact"></script>
 *
 * It injects an iframe pointing at /forms/<slug>/embed, right where the script
 * tag sits, and keeps its height in sync with the form's content (no scrollbars).
 *
 * Optional attributes:
 *   data-kiln-origin  Base URL of the CMS (defaults to this script's own origin)
 *   data-kiln-title   iframe title for assistive tech (defaults to "Form")
 *   data-kiln-height  Initial height in px before the first resize (default 480)
 *
 * No dependencies, no globals, safe to include more than once per page.
 */
(function () {
  "use strict";

  // Every iframe this script has mounted, so resize messages can be matched back
  // to the frame that sent them (a page may embed several forms).
  var mounted = [];

  function originOf(script) {
    var explicit = script.getAttribute("data-kiln-origin");
    if (explicit) return explicit.replace(/\/+$/, "");

    try {
      return new URL(script.src, window.location.href).origin;
    } catch (e) {
      return "";
    }
  }

  function mount(script) {
    var slug = script.getAttribute("data-kiln-form");
    if (!slug || script.getAttribute("data-kiln-mounted")) return;
    script.setAttribute("data-kiln-mounted", "1");

    var origin = originOf(script);
    var iframe = document.createElement("iframe");

    iframe.src = origin + "/forms/" + encodeURIComponent(slug) + "/embed";
    iframe.title = script.getAttribute("data-kiln-title") || "Form";
    iframe.loading = "lazy";
    iframe.setAttribute("scrolling", "no");
    iframe.style.width = "100%";
    iframe.style.border = "0";
    iframe.style.display = "block";
    iframe.style.height = (script.getAttribute("data-kiln-height") || "480") + "px";

    script.parentNode.insertBefore(iframe, script.nextSibling);
    mounted.push({ iframe: iframe, origin: origin });
  }

  window.addEventListener("message", function (event) {
    var data = event.data;
    if (!data || data.type !== "kiln-form-resize") return;

    for (var i = 0; i < mounted.length; i++) {
      var entry = mounted[i];
      if (event.source !== entry.iframe.contentWindow) continue;
      // Only trust a message from the CMS origin we pointed this frame at.
      if (entry.origin && event.origin !== entry.origin) return;

      var height = parseInt(data.height, 10);
      if (height > 0 && height < 20000) entry.iframe.style.height = height + "px";
      return;
    }
  });

  // `document.currentScript` is null when the tag carries defer/async, so fall
  // back to scanning for any not-yet-mounted embed tags.
  if (document.currentScript) {
    mount(document.currentScript);
  } else {
    var tags = document.querySelectorAll("script[data-kiln-form]");
    for (var i = 0; i < tags.length; i++) mount(tags[i]);
  }
})();
