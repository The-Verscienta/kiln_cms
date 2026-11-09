// Conditional custom fields in the content editor (#2277).
//
// `phx-hook="FieldConditions"` sits on the wrapper of a field (or of one
// sub-field cell of a group row) that carries `visible_when` / `required_when`.
// The server seeds the initial state (hidden class, `required`); after mount
// this hook owns visibility: it re-evaluates on every input/change in the form
// and again in `updated()`, because a LiveView patch resets the attributes the
// hook set. Rules are evaluated by `conditions.js`, the twin of
// `KilnCMS.CMS.Conditions`.
//
// Data attributes:
//   data-cf-prefix         the input-name prefix the rule's fields live under
//                          (`content[custom_fields]`, or a group row's)
//   data-cf-visible-when   rule JSON (optional)
//   data-cf-required-when  rule JSON (optional)
//   data-cf-required       "true" when the field is statically required
//
// Hiding is a class and `aria-hidden` only: the inputs stay enabled so the
// stored value still posts and round-trips. `required` is toggled for the
// field's own text-like control, never on a type=hidden input. A radio group
// (a select's radios or buttons widget, #2284) is required the way a browser
// requires one: `required` on its first option radio, and `aria-required` on
// the group (`role=radiogroup`) rather than on each radio.
import {holds, references} from "./conditions"

const parse = (json) => {
  if (!json) return null
  try { return JSON.parse(json) } catch (_e) { return null }
}

// The value of the field `name` under `prefix`, read from the form the way the
// server will see it: a list for `name[]` inputs, a boolean for a checkbox
// (false when its hidden "false" companion is there, missing otherwise).
export function readValue(form, prefix, name) {
  const single = `${prefix}[${name}]`
  const multi = `${single}[]`
  const els = Array.from(form.elements).filter((el) => el.name === single || el.name === multi)
  if (els.length === 0) return undefined

  const isMulti = els.some((el) => el.name === multi)
  if (isMulti) {
    const out = []
    for (const el of els) {
      if (el.tagName === "SELECT" && el.multiple) {
        Array.from(el.selectedOptions).forEach((o) => out.push(o.value))
      } else if (el.type === "checkbox" || el.type === "radio") {
        if (el.checked) out.push(el.value)
      } else {
        out.push(el.value)
      }
    }
    return out
  }

  const checkbox = els.find((el) => el.type === "checkbox")
  if (checkbox) {
    if (checkbox.checked) return true
    return els.some((el) => el.type === "hidden") ? false : undefined
  }

  const radios = els.filter((el) => el.type === "radio")
  if (radios.length > 0) {
    const on = radios.find((el) => el.checked)
    return on ? on.value : undefined
  }

  return els[els.length - 1].value
}

const CONTROLS = "input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=button]):not([type=submit]):not([type=file]), select, textarea"

export const FieldConditions = {
  mounted() {
    this.onInput = () => this.apply()
    this.bind()
    this.apply()
  },
  updated() {
    this.bind()
    this.apply()
  },
  destroyed() {
    this.unbind()
  },
  bind() {
    const form = this.el.closest("form")
    if (form === this.form) return
    this.unbind()
    this.form = form
    if (form) {
      form.addEventListener("input", this.onInput)
      form.addEventListener("change", this.onInput)
    }
  },
  unbind() {
    if (this.form) {
      this.form.removeEventListener("input", this.onInput)
      this.form.removeEventListener("change", this.onInput)
    }
    this.form = null
  },
  scope(rules) {
    const prefix = this.el.dataset.cfPrefix || ""
    const values = {}
    for (const rule of rules) {
      for (const name of references(rule)) {
        values[name] = readValue(this.form, prefix, name)
      }
    }
    return values
  },
  apply() {
    if (!this.form) return
    const visibleWhen = parse(this.el.dataset.cfVisibleWhen)
    const requiredWhen = parse(this.el.dataset.cfRequiredWhen)
    const values = this.scope([visibleWhen, requiredWhen])

    const hidden = visibleWhen ? !holds(visibleWhen, values, true) : false
    this.el.classList.toggle("hidden", hidden)
    this.el.classList.toggle("contents", !hidden)
    if (hidden) this.el.setAttribute("aria-hidden", "true")
    else this.el.removeAttribute("aria-hidden")

    if (this.el.dataset.cfRequiredWhen === undefined && this.el.dataset.cfRequired === undefined) return

    const required = !hidden &&
      (this.el.dataset.cfRequired === "true" ||
        (requiredWhen ? holds(requiredWhen, values, false) : false))
    const controls = Array.from(this.el.querySelectorAll(CONTROLS))
    for (const el of controls) {
      if (required) el.setAttribute("aria-required", "true")
      else el.removeAttribute("aria-required")
    }
    // A composite field's parts are not all required; only a lone control is
    // safe to flip.
    if (controls.length === 1) controls[0].required = required

    for (const group of this.el.querySelectorAll("[role=radiogroup]")) {
      if (required) group.setAttribute("aria-required", "true")
      else group.removeAttribute("aria-required")
      // On an option radio, not "— None —" (value ""), which the server drops
      // from the group once the field is required.
      const radios = Array.from(group.querySelectorAll("input[type=radio]")).filter((el) => el.value !== "")
      radios.forEach((el, i) => { el.required = required && i === 0 })
    }
  },
}
