// The browser evaluator against the shared fixture the Elixir module is also
// held to (test/kiln_cms/cms/conditions_test.exs). Run: `npm test` in assets/.
import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {dirname, join} from "node:path"

import {evaluate, holds, validShape, references, isEmpty} from "../js/conditions.js"

const here = dirname(fileURLToPath(import.meta.url))
const cases = JSON.parse(
  readFileSync(join(here, "../../test/support/fixtures/conditions_cases.json"), "utf8")
)

test("the fixture is not empty", () => {
  assert.ok(cases.length > 50)
})

for (const c of cases) {
  test(`evaluate: ${c.name}`, () => {
    assert.equal(evaluate(c.rule, c.values), c.expected)
  })
}

test("holds answers the fallback for no rule or a broken one", () => {
  assert.equal(holds(null, {}, true), true)
  assert.equal(holds({}, {}, false), false)
  assert.equal(holds({field: "a", op: "nope"}, {}, true), true)
  assert.equal(holds({field: "a", op: "eq", value: "x"}, {a: "y"}, true), false)
})

test("validShape limits depth, size and the in list", () => {
  const leaf = {field: "a", op: "eq", value: 1}
  assert.equal(validShape(leaf), true)
  assert.equal(validShape({all: []}), false)
  assert.equal(validShape({all: [leaf], any: [leaf]}), false)
  assert.equal(validShape({field: "a", op: "empty", value: 1}), false)
  assert.equal(validShape({field: "a", op: "in", value: "x"}), false)
  assert.equal(validShape({all: Array(10).fill(leaf)}), false)
  assert.equal(validShape({all: Array(9).fill(leaf)}), true)
  assert.equal(validShape({field: "a", op: "in", value: Array(51).fill(1)}), false)
})

test("numbers parse the way Float.parse does", () => {
  const eq5 = {field: "n", op: "eq", value: 5}
  for (const s of ["5", " 5 ", "+5", "5.0", "5e0", "0.5e1"]) {
    assert.equal(evaluate(eq5, {n: s}), true, s)
  }
  const eqHalf = {field: "n", op: "gt", value: 0}
  for (const s of [".5", "5.", "0x10", "1_000", "1e", "Infinity", "NaN"]) {
    assert.equal(evaluate(eqHalf, {n: s}), false, s)
  }
})

test("date and datetime never compare", () => {
  const rule = {field: "d", op: "gt", value: "2026-01-01"}
  assert.equal(evaluate(rule, {d: "2026-06-01T00:00:00Z"}), false)
  assert.equal(evaluate(rule, {d: "2026-06-01"}), true)
  assert.equal(evaluate(rule, {d: "2026-13-01"}), false)
})

test("a map equals nothing and is not empty", () => {
  assert.equal(isEmpty({id: "1"}), false)
  assert.equal(evaluate({field: "m", op: "neq", value: "x"}, {m: {id: "1"}}), true)
})

test("references lists each field once, in order", () => {
  const rule = {all: [{field: "b", op: "empty"}, {any: [{field: "a", op: "empty"}, {field: "b", op: "empty"}]}]}
  assert.deepEqual(references(rule), ["b", "a"])
})
