// Multi-page Kiln public forms (phase 5).
//
// A form with more than one .kiln-form-page is turned into a step-through:
// all but the current page are hidden, Previous/Next buttons are injected
// (labels come from the form's data attributes, so they're translated
// server-side), Next runs the current page through native validation, and
// the Submit button only shows on the last page. One POST at the end —
// nothing is stored per page. Without JS all pages render stacked and the
// form still works.
//
// Plain script (no bundler): loaded by the standalone embed page as well as
// regular pages. The embed iframe's height reporter uses a ResizeObserver,
// so page switches resize the host iframe automatically.
(function () {
  "use strict";

  function init(form) {
    if (form.dataset.kilnPaged === "1") return;
    var pages = form.querySelectorAll(".kiln-form-page");
    if (pages.length < 2) return;
    form.dataset.kilnPaged = "1";

    var submit = form.querySelector('button[type="submit"]');
    var steps = form.querySelector("[data-kiln-steps]");
    var fill = form.querySelector("[data-kiln-progress-fill]");
    var current = 0;

    var nav = document.createElement("div");
    nav.className = "kiln-form-nav flex items-center justify-between gap-2";

    var prev = document.createElement("button");
    prev.type = "button";
    prev.textContent = form.dataset.prevLabel || "Previous";
    prev.className =
      "rounded border border-base-300 px-4 py-2 text-sm font-medium";

    var next = document.createElement("button");
    next.type = "button";
    next.textContent = form.dataset.nextLabel || "Next";
    next.className =
      "rounded bg-primary px-4 py-2 text-sm font-medium text-primary-content";

    nav.appendChild(prev);
    nav.appendChild(next);
    if (submit && submit.parentNode === form) {
      form.insertBefore(nav, submit);
    } else {
      form.appendChild(nav);
    }

    function pageValid(page) {
      var inputs = page.querySelectorAll("input, select, textarea");
      for (var i = 0; i < inputs.length; i++) {
        var el = inputs[i];
        if (!el.disabled && !el.checkValidity()) {
          el.reportValidity();
          return false;
        }
      }

      // A required :checkboxes group can't use native `required`, so validate
      // it here (skip groups hidden by conditions — offsetParent is null).
      var groups = page.querySelectorAll("[data-kiln-required-group]");
      for (var g = 0; g < groups.length; g++) {
        var group = groups[g];
        if (group.offsetParent === null) continue;
        if (!group.querySelector("input[type=checkbox]:checked")) {
          var box = group.querySelector("input[type=checkbox]");
          if (box && box.setCustomValidity) {
            box.setCustomValidity("Please select at least one option.");
            box.reportValidity();
            box.setCustomValidity("");
          }
          return false;
        }
      }

      return true;
    }

    function show(index) {
      current = index;

      Array.prototype.forEach.call(pages, function (page, i) {
        page.style.display = i === index ? "" : "none";
      });

      prev.style.visibility = index === 0 ? "hidden" : "";
      next.style.display = index === pages.length - 1 ? "none" : "";
      if (submit) submit.style.display = index === pages.length - 1 ? "" : "none";

      if (steps) {
        var active = steps.getAttribute("data-active-class");
        var inactive = steps.getAttribute("data-inactive-class");
        Array.prototype.forEach.call(steps.children, function (li, i) {
          li.className = i <= index ? active : inactive;
          if (i === index) li.setAttribute("aria-current", "step");
          else li.removeAttribute("aria-current");
        });
      }

      if (fill) {
        fill.style.width = Math.round(((index + 1) / pages.length) * 100) + "%";
      }
    }

    prev.addEventListener("click", function () {
      if (current > 0) show(current - 1);
    });

    next.addEventListener("click", function () {
      if (!pageValid(pages[current])) return;
      if (current < pages.length - 1) show(current + 1);
    });

    show(0);
  }

  function initAll() {
    Array.prototype.forEach.call(
      document.querySelectorAll("form.kiln-form"),
      init
    );
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initAll);
  } else {
    initAll();
  }

  // LiveView-rendered pages: re-initialize after navigation/patches settle
  // (a patched form loses both the dataset flag and the injected nav).
  window.addEventListener("phx:page-loading-stop", initAll);
})();
