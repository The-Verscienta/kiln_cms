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

  function fieldValue(form, name) {
    var checked = form.querySelectorAll('[name="' + name + '[]"]:checked');
    if (checked.length > 0) {
      return Array.prototype.map.call(checked, function (el) {
        return el.value;
      });
    }
    if (form.querySelector('[name="' + name + '[]"]')) return [];

    var els = form.querySelectorAll('[name="' + name + '"]');
    if (els.length === 0) return null;

    var first = els[0];
    if (first.type === "radio") {
      var picked = form.querySelector('[name="' + name + '"]:checked');
      return picked ? picked.value : null;
    }
    if (first.type === "checkbox") {
      // boolean/consent: a hidden "false" twin precedes the checkbox.
      var box = form.querySelector('input[type=checkbox][name="' + name + '"]');
      return box && box.checked ? "true" : "false";
    }
    if (first.type === "hidden" && els.length > 1) {
      // hidden "false" + something else — prefer the visible input.
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

      wrap.style.display = show ? "" : "none";
      Array.prototype.forEach.call(
        wrap.querySelectorAll("input, select, textarea"),
        function (el) {
          el.disabled = !show;
        }
      );
    });
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
