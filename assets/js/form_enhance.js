// Conditional fields on public forms (#2262): shows and hides each field as
// the visitor answers the ones before it.
//
// The server marks a form that has a condition with `data-kiln-enhance`
// (`KilnCMSWeb.BlockComponents.public_form/1`): every field wrapper carries
// `data-kiln-field` (its name), and a conditional one `data-kiln-condition`
// (the rule the server applies, as JSON). Its required controls carry
// `data-kiln-required` instead of `required`, so with no script every field
// is shown and none blocks the form; the server drops what a hidden field
// sent either way.
//
// Once this runs, a hidden field's wrapper gets `hidden` and every control in
// it `disabled` (the boolean's "false" companion included), so it is neither
// validated nor posted; a shown one gets its `required` back. Plain DOM, no
// LiveView: it runs on dead-rendered pages only. Inside a LiveView (a
// preview) every field stays shown, since a patch would undo what this sets.
import {visibility} from "./form_logic.js"
import {readControlValue} from "./field_conditions.js"

const CONTROLS = "input, select, textarea, button, fieldset"

const parse = (json) => {
  if (!json) return null
  try { return JSON.parse(json) } catch (_e) { return null }
}

function apply(form) {
  const wrappers = Array.from(form.querySelectorAll("[data-kiln-field]"))
  const fields = wrappers.map((el) => ({
    name: el.dataset.kilnField,
    condition: parse(el.dataset.kilnCondition),
  }))

  const values = {}
  for (const {name} of fields) {
    const value = readControlValue(form, name, `${name}[]`)
    if (value !== undefined) values[name] = value
  }

  const shown = visibility(fields, values)

  wrappers.forEach((el, i) => {
    if (!fields[i].condition) return
    const visible = shown[fields[i].name] !== false
    el.hidden = !visible
    for (const control of el.querySelectorAll(CONTROLS)) {
      control.disabled = !visible
      if (control.hasAttribute("data-kiln-required")) control.required = visible
    }
  })
}

// Wires every marked form under `root` once. Idempotent.
export function enhanceForms(root = document) {
  for (const form of root.querySelectorAll("form.kiln-form[data-kiln-enhance]")) {
    if (form.hasAttribute("data-kiln-enhanced")) continue
    if (form.closest("[data-phx-session]")) continue
    form.setAttribute("data-kiln-enhanced", "")

    for (const hint of form.querySelectorAll(".kiln-form-condition-hint")) hint.hidden = true

    const onChange = () => apply(form)
    form.addEventListener("input", onChange)
    form.addEventListener("change", onChange)
    // A reset fires before the controls take their defaults back.
    form.addEventListener("reset", () => setTimeout(onChange, 0))
    apply(form)
  }
}

export function enhanceFormsWhenReady(doc = document) {
  if (doc.readyState === "loading") {
    doc.addEventListener("DOMContentLoaded", () => enhanceForms(doc), {once: true})
  } else {
    enhanceForms(doc)
  }
}
