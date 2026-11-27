// The public form's visibility rules (#2262) against the shared fixture the
// Elixir module is also held to (test/kiln_cms/forms/logic_test.exs), and the
// control reader the form script uses. Run: `npm test` in assets/.
import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {dirname, join} from "node:path"

import {visibility, effective} from "../js/form_logic.js"
import {readControlValue} from "../js/field_conditions.js"

const here = dirname(fileURLToPath(import.meta.url))
const cases = JSON.parse(
  readFileSync(join(here, "../../test/support/fixtures/form_visibility_cases.json"), "utf8")
)

test("the fixture is not empty", () => {
  assert.ok(cases.length > 20)
})

for (const c of cases) {
  test(`visibility: ${c.name}`, () => {
    assert.deepEqual(visibility(c.fields, c.values), c.expected)
  })
}

test("effective drops a condition naming a field that is not earlier", () => {
  const rule = {field: "a", op: "eq", value: "x"}
  assert.equal(effective({action: "show", rule}, new Set()), null)
  assert.deepEqual(effective({action: "show", rule}, new Set(["a"])), {action: "show", rule})
  assert.equal(effective(null, new Set(["a"])), null)
  assert.equal(effective({action: "show"}, new Set(["a"])), null)
})

// A stand-in for `form.elements`: only what readControlValue reads.
const form = (els) => ({elements: els})
const el = (attrs) => ({tagName: "INPUT", type: "text", value: "", checked: false, ...attrs})

test("readControlValue reads a public form's unprefixed controls", () => {
  assert.equal(readControlValue(form([el({name: "a", value: "x"})]), "a", "a[]"), "x")
  assert.equal(readControlValue(form([el({name: "b", value: "x"})]), "a", "a[]"), undefined)
})

test("readControlValue reads a boolean through its false companion", () => {
  const off = [el({name: "agree", type: "hidden", value: "false"}), el({name: "agree", type: "checkbox", value: "true"})]
  assert.equal(readControlValue(form(off), "agree", "agree[]"), false)
  off[1].checked = true
  assert.equal(readControlValue(form(off), "agree", "agree[]"), true)
})

test("readControlValue reads checkboxes as a list and radios as the checked one", () => {
  const boxes = [
    el({name: "c[]", type: "checkbox", value: "Red", checked: true}),
    el({name: "c[]", type: "checkbox", value: "Blue"}),
  ]
  assert.deepEqual(readControlValue(form(boxes), "c", "c[]"), ["Red"])

  const radios = [
    el({name: "s", type: "radio", value: "S"}),
    el({name: "s", type: "radio", value: "M", checked: true}),
  ]
  assert.equal(readControlValue(form(radios), "s", "s[]"), "M")
  radios[1].checked = false
  assert.equal(readControlValue(form(radios), "s", "s[]"), undefined)
})
