// Which fields of a public form are shown (#2262): the browser's twin of
// `KilnCMS.Forms.Logic` (lib/kiln_cms/forms/logic.ex). Both are run against
// `test/support/fixtures/form_visibility_cases.json` (assets/test/), and the
// rules themselves are evaluated by `conditions.js`, the twin of
// `KilnCMS.CMS.Conditions`.
//
//   1. Fields are evaluated in form order.
//   2. A rule may name only earlier fields.
//   3. A rule sees the values of earlier shown fields only.
//   4. "show" shows the field while the rule holds, "hide" hides it.
//   5. A condition that can't be applied (broken shape, naming a field that
//      is missing or not earlier, an unknown action) leaves the field shown.
//
// Pure: no DOM, so `node --test` loads it as it is.
import {validShape, references, evaluate} from "./conditions.js"

const ACTIONS = ["show", "hide"]

// The condition to apply to a field, given the names before it, or null.
export function effective(condition, earlier) {
  if (!condition || typeof condition !== "object") return null
  if (!ACTIONS.includes(condition.action)) return null
  if (!validShape(condition.rule)) return null
  if (!references(condition.rule).every((name) => earlier.has(name))) return null
  return condition
}

// `fields` is [{name, condition}] in form order, `values` field name -> the
// value sent. Answers {name: shown}.
export function visibility(fields, values) {
  const shown = {}
  const scope = {}
  const earlier = new Set()
  const has = (name) => Object.prototype.hasOwnProperty.call(values || {}, name)

  for (const field of fields) {
    const condition = effective(field.condition, earlier)
    let visible = true
    if (condition) {
      const holds = evaluate(condition.rule, scope)
      visible = condition.action === "show" ? holds : !holds
    }
    shown[field.name] = visible
    if (visible && has(field.name)) scope[field.name] = values[field.name]
    earlier.add(field.name)
  }

  return shown
}
