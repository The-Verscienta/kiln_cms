/*!
 * KilnCMS embeddable forms — iframe-side height reporter.
 *
 * Loaded only by /forms/:slug/embed. Tells the host page how tall the form is,
 * so `/embed.js` can size the iframe and avoid an inner scrollbar. Runs again
 * after the form posts (validation errors and the thank-you page change height).
 *
 * The message is posted with targetOrigin "*" because the page can't know which
 * site framed it. That's fine: the payload is a single integer height, and the
 * host snippet ignores messages that don't come from its own iframe.
 */
(function () {
  "use strict";

  // Not framed (someone opened the embed URL directly) — nothing to report.
  if (window.parent === window) return;

  var last = 0;

  function report() {
    var height = Math.ceil(document.documentElement.getBoundingClientRect().height);
    if (!height || height === last) return;
    last = height;
    window.parent.postMessage({ type: "kiln-form-resize", height: height }, "*");
  }

  document.addEventListener("DOMContentLoaded", report);
  window.addEventListener("load", report);
  window.addEventListener("resize", report);

  if (window.ResizeObserver) {
    new ResizeObserver(report).observe(document.documentElement);
  }

  report();
})();
