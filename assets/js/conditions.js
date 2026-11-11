// Conditional rules for custom fields (#2277): the browser's twin of
// `KilnCMS.CMS.Conditions` (lib/kiln_cms/cms/conditions.ex). It must answer
// exactly as the Elixir module does; both are run against one fixture,
// `test/support/fixtures/conditions_cases.json` (see assets/test/).
//
// A rule is plain JSON: a leaf {field, op, value}, or {all: [..]} / {any: [..]}.
// Pure: no DOM, no imports, so `node --test` loads it as it is.

const OPS = ["eq", "neq", "in", "empty", "not_empty", "gt", "lt"]
const VALUE_OPS = ["eq", "neq", "gt", "lt"]
const MAX_DEPTH = 3
const MAX_NODES = 10
const MAX_IN = 50

const isMap = (v) => v !== null && typeof v === "object" && !Array.isArray(v)
const isScalar = (v) => typeof v === "string" || typeof v === "boolean" ||
  (typeof v === "number" && Number.isFinite(v))
const has = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key)

// --- shape ---------------------------------------------------------------

// The node count of a well-formed rule, or null.
function shape(rule, depth) {
  if (depth > MAX_DEPTH) return null
  if (!isMap(rule)) return null
  if (has(rule, "all")) return combinator(rule, rule.all, depth)
  if (has(rule, "any")) return combinator(rule, rule.any, depth)
  if (has(rule, "field") && has(rule, "op")) return leaf(rule)
  return null
}

function combinator(rule, children, depth) {
  if (Object.keys(rule).length !== 1) return null
  if (!Array.isArray(children) || children.length === 0) return null
  let count = 1
  for (const child of children) {
    const n = shape(child, depth + 1)
    if (n === null) return null
    count += n
  }
  return count
}

function leaf(rule) {
  const extra = Object.keys(rule).filter((k) => !["field", "op", "value"].includes(k))
  if (extra.length > 0) return null
  if (!(typeof rule.field === "string" && rule.field !== "")) return null
  if (!OPS.includes(rule.op)) return null
  const value = rule.value === undefined ? null : rule.value

  if (VALUE_OPS.includes(rule.op)) return isScalar(value) ? 1 : null

  if (rule.op === "in") {
    return Array.isArray(value) && value.length > 0 && value.length <= MAX_IN &&
      value.every(isScalar) ? 1 : null
  }

  return value === null ? 1 : null
}

// null / an empty object is "no rule"; otherwise a rule is valid when its
// shape is and it has at most MAX_NODES nodes.
export function validShape(rule) {
  if (rule === null || rule === undefined) return false
  if (isMap(rule) && Object.keys(rule).length === 0) return false
  const nodes = shape(rule, 1)
  return nodes !== null && nodes <= MAX_NODES
}

// The field names a rule reads, in order of first use.
export function references(rule) {
  const out = []
  const walk = (node) => {
    if (!isMap(node)) return
    if (Array.isArray(node.all)) node.all.forEach(walk)
    else if (Array.isArray(node.any)) node.any.forEach(walk)
    else if (typeof node.field === "string" && !out.includes(node.field)) out.push(node.field)
  }
  walk(rule)
  return out
}

// --- values --------------------------------------------------------------

// Missing, null, "", whitespace, [] or a list of nothing but those. false,
// 0 and an object (a media snapshot) are values.
export function isEmpty(value) {
  if (value === null || value === undefined) return true
  if (typeof value === "string") return value.trim() === ""
  if (Array.isArray(value)) return value.every(isEmpty)
  return false
}

// Booleans are not numbers; a string is one only when all of it is, and in
// Elixir's `Float.parse` terms: ".5", "5.", "0x10", "1_000" are not.
const NUMBER = /^[+-]?\d+(\.\d+)?([eE][+-]?\d+)?$/

function number(value) {
  if (typeof value === "boolean") return null
  if (typeof value === "number") return Number.isFinite(value) ? value : null
  if (typeof value === "string") {
    const s = value.trim()
    if (!NUMBER.test(s)) return null
    const n = Number(s)
    return Number.isFinite(n) ? n : null
  }
  return null
}

// Only scalars have a text; an object equals nothing.
function text(value) {
  if (typeof value === "string") return value.trim()
  if (typeof value === "number" || typeof value === "boolean") return String(value)
  return null
}

function matches(actual, expected) {
  if (Array.isArray(actual)) return actual.some((a) => matches(a, expected))
  if (isEmpty(actual)) return false
  const a = number(actual)
  const e = number(expected)
  if (a !== null && e !== null) return a === e
  const t = text(actual)
  return t !== null && t === text(expected)
}

// A date compares as days, a datetime as microseconds; the two never mix.
const DATE = /^(\d{4})-(\d{2})-(\d{2})$/
const DATETIME = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:[.,](\d+))?(Z|[+-]\d{2}(?::?\d{2})?)?$/

function days(y, m, d) {
  const date = new Date(0)
  date.setUTCFullYear(y, m - 1, d)
  if (date.getUTCFullYear() !== y || date.getUTCMonth() !== m - 1 || date.getUTCDate() !== d) {
    return null
  }
  return Math.round(date.getTime() / 86400000)
}

function moment(value) {
  if (typeof value !== "string") return null
  const s = value.trim()

  let m = DATE.exec(s)
  if (m) {
    const n = days(+m[1], +m[2], +m[3])
    return n === null ? null : {kind: "date", at: n}
  }

  m = DATETIME.exec(s)
  if (!m) return null
  const day = days(+m[1], +m[2], +m[3])
  const [h, min, sec] = [+m[4], +m[5], +m[6]]
  if (day === null || h > 23 || min > 59 || sec > 59) return null

  const micros = m[7] ? Number(m[7].slice(0, 6).padEnd(6, "0")) : 0
  let offset = 0
  const zone = m[8]
  if (zone && zone !== "Z") {
    const digits = zone.slice(1).replace(":", "")
    const oh = +digits.slice(0, 2)
    const om = digits.length > 2 ? +digits.slice(2, 4) : 0
    if (oh > 23 || om > 59) return null
    // "-00:00" is not a valid offset to Elixir's parser.
    if (zone[0] === "-" && oh === 0 && om === 0) return null
    offset = (zone[0] === "-" ? -1 : 1) * (oh * 3600 + om * 60)
  }

  const seconds = day * 86400 + h * 3600 + min * 60 + sec - offset
  return {kind: "datetime", at: seconds * 1e6 + micros}
}

// "gt", "lt", "eq" or null (not comparable).
function compare(actual, expected) {
  if (Array.isArray(actual)) return null
  let a = number(actual)
  let e = number(expected)

  if (a === null || e === null) {
    const ma = moment(actual)
    const me = moment(expected)
    if (!ma || !me || ma.kind !== me.kind) return null
    a = ma.at
    e = me.at
  }

  return a > e ? "gt" : a < e ? "lt" : "eq"
}

function test(op, actual, expected) {
  switch (op) {
    case "empty": return isEmpty(actual)
    case "not_empty": return !isEmpty(actual)
    case "eq": return matches(actual, expected)
    case "neq": return !matches(actual, expected)
    case "in": return expected.some((e) => matches(actual, e))
    case "gt": return compare(actual, expected) === "gt"
    case "lt": return compare(actual, expected) === "lt"
    default: return false
  }
}

function run(rule, values) {
  if (has(rule, "all")) return rule.all.every((c) => run(c, values))
  if (has(rule, "any")) return rule.any.some((c) => run(c, values))
  const actual = has(values, rule.field) ? values[rule.field] : undefined
  return test(rule.op, actual, rule.value === undefined ? null : rule.value)
}

// Whether `rule` holds for `values` (field name -> value). Never throws: an
// absent or broken rule is false.
export function evaluate(rule, values) {
  if (!validShape(rule)) return false
  return run(rule, values || {})
}

// Like `evaluate`, but a rule that is absent or cannot be read answers
// `fallback`: a broken rule never hides a field or blocks a save.
export function holds(rule, values, fallback) {
  return validShape(rule) ? run(rule, values || {}) : fallback
}
