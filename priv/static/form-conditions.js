// Conditional visibility for Kiln public forms ("smart logic").
//
// Each conditional field's wrapper carries data-kiln-conditions (JSON:
// {logic: "all"|"any", rules: [{field, operator, value}]}). This script
// evaluates the rules against the form's current values and toggles the
// wrapper — hiding also disables the inputs so a hidden `required` field
// can't block native validation and sends no value.
//
// The server re-evaluates the same rules on submit (KilnCMS.Forms) — this
// file is UX only. Plain script (no bundler): it's loaded by the standalone
// embed page as well as regular pages, and delegates events at the document
// level so LiveView-patched DOM keeps working.
(function () {
  "use strict";

  function enabled(el) {
    // A field hidden by its own conditions has disabled inputs (and won't POST)
    // — the server discards it, so we must read it as empty here too.
    return !el.disabled;
  }

  function fieldValue(form, name) {
    // Multi-select checkboxes (name[]): the selected, enabled values.
    var group = form.querySelectorAll('[name="' + name + '[]"]');
    if (group.length > 0) {
      var picked = [];
      Array.prototype.forEach.call(group, function (el) {
        if (el.checked && enabled(el)) picked.push(el.value);
      });
      return picked;
    }

    var els = Array.prototype.filter.call(
      form.querySelectorAll('[name="' + name + '"]'),
      enabled
    );
    if (els.length === 0) return null;

    if (els[0].type === "radio") {
      for (var i = 0; i < els.length; i++) {
        if (els[i].checked) return els[i].value;
      }
      return null;
    }

    // boolean/consent: a hidden "false" twin PRECEDES the checkbox, so we must
    // find the checkbox among the elements (not assume it's first) and read its
    // checked state — not its constant `value="true"` attribute.
    for (var j = 0; j < els.length; j++) {
      if (els[j].type === "checkbox") {
        return els[j].checked ? "true" : "false";
      }
    }

    var first = els[0];
    if (first.type === "hidden" && els.length > 1) {
      first = els[els.length - 1];
    }
    return first.value;
  }

  function toNumber(value) {
    if (typeof value === "number") return value;
    if (typeof value !== "string" || value.trim() === "") return NaN;
    return Number(value);
  }

  function matches(rule, value) {
    var target = rule.value == null ? "" : String(rule.value);

    switch (rule.operator || "eq") {
      case "eq":
        if (Array.isArray(value)) return value.indexOf(target) !== -1;
        return String(value == null ? "" : value) === target;
      case "neq":
        return !matches({operator: "eq", value: rule.value}, value);
      case "contains":
        if (Array.isArray(value)) return value.indexOf(target) !== -1;
        return String(value == null ? "" : value).indexOf(target) !== -1;
      case "empty":
        return value == null || value === "" || (Array.isArray(value) && value.length === 0);
      case "not_empty":
        return !matches({operator: "empty"}, value);
      case "gt": {
        var l = toNumber(value), r = toNumber(target);
        return !isNaN(l) && !isNaN(r) && l > r;
      }
      case "lt": {
        var l2 = toNumber(value), r2 = toNumber(target);
        return !isNaN(l2) && !isNaN(r2) && l2 < r2;
      }
      default:
        // Unknown operator — never hide the field.
        return true;
    }
  }

  function evaluateForm(form) {
    var wrappers = form.querySelectorAll("[data-kiln-conditions]");

    // Iterate to a fixpoint: hiding one field changes what a rule referencing
    // it sees, so a single pass is order-dependent (a rule can read a field
    // whose own visibility hasn't been decided yet). Re-evaluate until nothing
    // changes — the server does the same via its visibility fixpoint. Bounded
    // by the number of wrappers, with a hard guard.
    var changed = true;
    var guard = 0;

    while (changed && guard++ < wrappers.length + 1) {
      changed = false;

      Array.prototype.forEach.call(wrappers, function (wrap) {
        var conf;
        try {
          conf = JSON.parse(wrap.getAttribute("data-kiln-conditions"));
        } catch (_e) {
          return;
        }

        var rules = (conf && conf.rules) || [];
        var results = rules.map(function (rule) {
          // An in-progress rule (blank field) never hides anything.
          if (!rule || !rule.field) return true;
          return matches(rule, fieldValue(form, rule.field));
        });

        var show =
          conf && conf.logic === "any"
            ? results.length === 0 || results.some(Boolean)
            : results.every(Boolean);

        if (show === (wrap.style.display === "none")) {
          changed = true;
          wrap.style.display = show ? "" : "none";
          Array.prototype.forEach.call(
            wrap.querySelectorAll("input, select, textarea"),
            function (el) {
              el.disabled = !show;
            }
          );
        }
      });
    }
  }

  function evaluateAll() {
    Array.prototype.forEach.call(
      document.querySelectorAll("form.kiln-form"),
      evaluateForm
    );
  }

  function onEvent(event) {
    var form = event.target && event.target.closest && event.target.closest("form.kiln-form");
    if (form) evaluateForm(form);
  }

  document.addEventListener("input", onEvent);
  document.addEventListener("change", onEvent);

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", evaluateAll);
  } else {
    evaluateAll();
  }

  // LiveView-rendered pages: re-evaluate after navigation/patches settle.
  window.addEventListener("phx:page-loading-stop", evaluateAll);
})();
