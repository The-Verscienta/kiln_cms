// Click-to-locate for the editor's advisory panels (SEO, accessibility,
// compliance). A finding row in the sidebar is a button carrying `data-jump-*`
// attributes — see `KilnCMSWeb.AdvisoryComponents.jump_attrs/2` for the
// server side of the contract:
//
//   data-jump-code    the finding code, e.g. `images_missing_alt`
//   data-jump-field   the input it concerns: `body`, `images`, `seo_title`, …
//   data-jump-blocks  comma-separated top-level block indexes, when known
//   data-jump-text    an example phrase (a shouted run, a "click here")
//   data-jump-max     a word limit (long paragraphs / sentences)
//   data-jump-level   the heading level that skipped
//   data-jump-hrefs   JSON list of link paths that don't resolve
//
// Resolution goes from most to least specific: the exact element inside a
// block (the alt input, the offending <a>, the empty <h3>), else the block,
// else the sidebar field, else the whole block canvas. Whatever is found gets
// scrolled into view; the block pulses (the same `kiln-focus-pulse` the
// deep-link hook uses) and the exact element is outlined for a few seconds.
// An input target is focused too, so the author can start typing the fix.
//
// One delegated listener on the document rather than a LiveView hook: the
// findings list re-renders on every keystroke, and a document listener needs
// no stable id to survive that.

const MARK_CLASS = "kiln-issue-mark"
const PULSE_CLASS = "kiln-focus-pulse"
const HIGHLIGHT_NAME = "kiln-issue"
const MARK_MS = 6000
const PULSE_MS = 1600
const HEADINGS = "h1,h2,h3,h4,h5,h6"
const FORM_FIELDS = ["body", "images"]
// Mirrors `Kiln.Advisory.Checks.LinkText`'s bare-URL shape.
const BARE_URL = /^(?:[a-z][a-z0-9+.-]*:\/\/\S+|www\.\S+|\/\S*|[\w-]+(?:\.[\w-]+)+\/\S*)$/i

let marked = []
let clearTimer = null

export function initAdvisoryJump(root = document) {
  root.addEventListener("click", e => {
    const trigger = e.target.closest("[data-advisory-jump]")
    if (!trigger) return
    e.preventDefault()
    jumpTo(trigger.dataset)
  })
}

// Resolve the finding described by `data` (a dataset: camel-cased keys) and
// bring the editor to it. Exported so the e2e suite can drive it directly.
export function jumpTo(data) {
  clearMarks()
  const target = resolve(data)
  if (!target) return false
  show(target)
  return true
}

function resolve(d) {
  const blocks = blockElements(d.jumpBlocks)
  if (blocks.length) {
    const inner = blocks.flatMap(block => withinBlock(block, d))
    return {scroll: inner[0] || blocks[0], pulse: blocks, marks: inner, focus: inner[0]}
  }

  if (d.jumpField && !FORM_FIELDS.includes(d.jumpField)) {
    const input = fieldInput(d.jumpField)
    if (input) return {scroll: input, pulse: [input.closest("div") || input], marks: [], focus: input}
  }

  const canvas = document.getElementById("blocks-sortable")
  if (!canvas) return null

  const found = withinBody(canvas, d)
  if (found.range) {
    const el = rangeElement(found.range)
    return {scroll: el, pulse: [topBlock(el)], marks: [], range: found.range}
  }
  if (found.marks.length) {
    return {scroll: found.marks[0], pulse: [topBlock(found.marks[0])], marks: found.marks, focus: found.marks[0]}
  }
  return {scroll: canvas, pulse: [canvas], marks: []}
}

// ── Inside a named block ────────────────────────────────────────────────────

function withinBlock(block, d) {
  const pm = block.querySelector(".ProseMirror")
  switch (d.jumpCode) {
    case "images_missing_alt":
      return all(block, 'input[name$="[alt]"]')
    case "headings_empty":
      return pm ? all(pm, HEADINGS).filter(blank) : headingInputs(block)
    case "heading_levels_skipped":
      return pm ? all(pm, `h${d.jumpLevel}`).slice(0, 1) : headingInputs(block)
    case "link_text_empty":
      return pm ? all(pm, "a").filter(blank) : []
    case "link_text_uninformative": {
      if (!pm) return []
      const links = all(pm, "a")
      const exact = links.filter(a => fold(a.textContent) === fold(d.jumpText || ""))
      return exact.length ? exact : links
    }
    case "link_text_bare_url":
      return pm ? all(pm, "a").filter(a => BARE_URL.test(a.textContent.trim())) : []
    case "internal_links_missing":
    case "internal_links_unpublished": {
      if (!pm) return []
      const hrefs = parseJson(d.jumpHrefs)
      return all(pm, "a").filter(a => hrefs.includes(a.getAttribute("href")))
    }
    default:
      return []
  }
}

// ── Body-wide findings with no block index ──────────────────────────────────

function withinBody(canvas, d) {
  const none = {marks: [], range: null}
  const max = Number(d.jumpMax)
  switch (d.jumpCode) {
    case "long_paragraphs":
      return {...none, marks: paragraphs(canvas).filter(p => words(p.textContent) > max)}
    case "long_sentences":
      return {
        ...none,
        marks: paragraphs(canvas).filter(p => sentences(p.textContent).some(s => words(s) > max)),
      }
    case "keyphrase_not_in_first_paragraph":
      return {...none, marks: paragraphs(canvas).slice(0, 1)}
    case "keyphrase_not_in_headings":
      return {...none, marks: [...all(canvas, `.ProseMirror :is(${HEADINGS})`), ...headingInputs(canvas)]}
    default:
      return d.jumpText ? findText(canvas, d.jumpText) : none
  }
}

// The example phrase, wherever it is: a text range inside a rich-text block
// (highlighted with the CSS Custom Highlight API where the browser has it),
// or a heading input whose value contains it (focused with the run selected).
function findText(canvas, needle) {
  for (const input of headingInputs(canvas)) {
    const at = input.value.indexOf(needle)
    if (at >= 0) {
      input.dataset.kilnSelect = `${at},${at + needle.length}`
      return {marks: [input], range: null}
    }
  }
  for (const pm of all(canvas, ".ProseMirror")) {
    const range = textRange(pm, needle)
    if (range) return {marks: [], range}
  }
  return {marks: [], range: null}
}

function textRange(root, needle) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  const nodes = []
  let text = ""
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    nodes.push({node, start: text.length})
    text += node.data
  }
  const at = text.indexOf(needle)
  if (at < 0) return null
  const range = document.createRange()
  const from = locate(nodes, at)
  const to = locate(nodes, at + needle.length)
  range.setStart(from.node, from.offset)
  range.setEnd(to.node, to.offset)
  return range
}

function locate(nodes, offset) {
  let hit = nodes[0]
  for (const entry of nodes) {
    if (entry.start > offset) break
    hit = entry
  }
  return {node: hit.node, offset: Math.min(offset - hit.start, hit.node.data.length)}
}

// ── Showing the result ──────────────────────────────────────────────────────

function show(t) {
  for (const el of t.pulse) pulse(el)
  for (const el of t.marks) {
    el.classList.add(MARK_CLASS)
    marked.push(el)
  }
  if (t.range) setHighlight(t.range)

  const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches
  t.scroll.scrollIntoView({behavior: reduce ? "auto" : "smooth", block: "center"})

  const focus = t.focus
  if (focus && typeof focus.focus === "function" && !focus.isContentEditable && !focus.closest(".ProseMirror")) {
    focus.focus({preventScroll: true})
    const sel = focus.dataset.kilnSelect
    if (sel && typeof focus.setSelectionRange === "function") {
      const [from, to] = sel.split(",").map(Number)
      focus.setSelectionRange(from, to)
    }
    delete focus.dataset.kilnSelect
  }

  clearTimer = setTimeout(clearMarks, MARK_MS)
}

function pulse(el) {
  el.classList.remove(PULSE_CLASS)
  // Re-trigger the animation if it's already running on this element.
  void el.offsetWidth
  el.classList.add(PULSE_CLASS)
  setTimeout(() => el.classList.remove(PULSE_CLASS), PULSE_MS)
}

function setHighlight(range) {
  if (typeof Highlight === "undefined" || !CSS.highlights) {
    // No Custom Highlight API: outline the containing paragraph instead.
    const el = rangeElement(range)
    el.classList.add(MARK_CLASS)
    marked.push(el)
    return
  }
  CSS.highlights.set(HIGHLIGHT_NAME, new Highlight(range))
}

function clearMarks() {
  if (clearTimer) clearTimeout(clearTimer)
  clearTimer = null
  for (const el of marked) el.classList.remove(MARK_CLASS)
  marked = []
  if (typeof CSS !== "undefined" && CSS.highlights) CSS.highlights.delete(HIGHLIGHT_NAME)
}

// ── Lookups ─────────────────────────────────────────────────────────────────

function blockElements(list) {
  if (!list) return []
  return list
    .split(",")
    .map(i => document.getElementById(`block-${i.trim()}`))
    .filter(Boolean)
}

function fieldInput(field) {
  const sel = CSS.escape(field)
  return (
    document.querySelector(`:is(input,textarea,select)[phx-value-field="${sel}"]`) ||
    document.querySelector(`[phx-value-field="${sel}"]`)
  )
}

function headingInputs(root) {
  return all(root, '[data-block-type="heading"] :is(input,textarea)[name$="[text]"]')
}

function paragraphs(canvas) {
  return all(canvas, ".ProseMirror p").filter(p => !blank(p))
}

function topBlock(el) {
  return el.closest('[id^="block-"][data-sort-id]') || el
}

function rangeElement(range) {
  const node = range.startContainer
  const el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement
  return el.closest(`p,li,blockquote,td,th,${HEADINGS}`) || el
}

function all(root, selector) {
  return Array.from(root.querySelectorAll(selector))
}

function blank(el) {
  return el.textContent.trim() === ""
}

function fold(text) {
  return text.trim().toLowerCase().replace(/\s+/g, " ")
}

function words(text) {
  return text.split(/\s+/).filter(Boolean).length
}

// Same split as `Kiln.Advisory.Body.sentences/1`.
function sentences(text) {
  return text.split(/(?<=[.!?。！？])\s+/).filter(s => s.trim() !== "")
}

function parseJson(value) {
  try {
    const parsed = JSON.parse(value || "[]")
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}
