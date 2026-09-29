// Lists the author didn't mark up as lists: turn them into real ones.
//
// StarterKit already turns a typed "- ", "* ", "+ " or "1. " into a list.
// This covers what it misses:
//
//   * typing: a "•" (⌥8 on a Mac), "◦", "▪", "‣" or "–" followed by a space
//     starts a bullet list, and "1) " starts a numbered one
//   * pasting from Word or Outlook: their HTML has no <ul>/<ol>, only
//     paragraphs styled `mso-list` with the marker in an `mso-list:Ignore`
//     span. They are rebuilt as nested <ul>/<ol> before ProseMirror parses them
//   * pasting anything else that gives a run of paragraphs starting with a
//     bullet glyph or with "1." / "2." … (a PDF, a plain-text email, a web page
//     that draws its bullets as characters). Each run becomes a list and the
//     markers are dropped
//
// Plain-text Markdown lists ("- a\n- b") are markdown_paste.js's: it claims the
// paste before any of this runs. That module also calls `normalizeBullets` so
// a "•" line inside pasted Markdown reaches the server's converter as "- ".
//
// Portable Text keeps no start number on a list, so a numbered list here always
// starts at 1. A pasted run is taken as numbered only when it counts 1, 2, 3 …;
// "2024. A good year" on its own stays a paragraph.
import {Extension, wrappingInputRule} from "@tiptap/core"
import {Plugin, PluginKey} from "@tiptap/pm/state"
import {Fragment, Slice} from "@tiptap/pm/model"

// Characters that only ever mean "bullet" at the start of a line. `·` is what
// Word's Symbol-font bullet becomes as text.
const GLYPHS = "•◦▪▫‣⁃●○■□∙·"
// A single line starting with one of these is a list item. Hyphens,
// asterisks and dashes also start ordinary sentences, so they need a second
// line before a pasted run counts.
const GLYPH_BULLET = new RegExp(`^\\s*[${GLYPHS}]\\s+`)
const WEAK_BULLET = /^\s*[-*+–—]\s+/
const NUMBERED = /^\s*(\d{1,3})[.)]\s+/

// "• item" → "- item", line by line, for text headed to the Markdown converter.
export function normalizeBullets(text) {
  return text.replace(new RegExp(`^([ \\t]*)[${GLYPHS}][ \\t\\u00a0]+`, "gm"), "$1- ")
}

// What a pasted paragraph's text says it is: a bullet, the nth numbered item,
// or neither. `length` is how many characters of marker to drop.
function markerOf(text) {
  let m = text.match(GLYPH_BULLET)
  if (m) return {kind: "bullet", strong: true, length: m[0].length}
  m = text.match(WEAK_BULLET)
  if (m) return {kind: "bullet", strong: false, length: m[0].length}
  m = text.match(NUMBERED)
  if (m) return {kind: "ordered", n: parseInt(m[1], 10), length: m[0].length}
  return null
}

// Split the slice's top-level paragraphs into runs of list items. A run is one
// kind throughout, and a numbered run counts up from 1 without a gap.
function listRuns(nodes) {
  const runs = []
  let run = null

  nodes.forEach((node, i) => {
    const marker = node.type.name === "paragraph" && node.firstChild && node.firstChild.isText
      ? markerOf(node.firstChild.text)
      : null
    // The marker must sit wholly in the first text node, or cutting it off
    // would cut into whatever follows.
    const fits = marker && node.firstChild.text.length > marker.length

    const continues =
      fits &&
      run &&
      run.kind === marker.kind &&
      (marker.kind === "bullet" || marker.n === run.next)

    if (continues) {
      run.items.push({node, cut: marker.length})
      run.end = i
      run.strong = run.strong || marker.strong
      if (marker.kind === "ordered") run.next++
      return
    }

    if (run) runs.push(run)
    run = null
    if (fits && (marker.kind === "bullet" || marker.n === 1)) {
      run = {
        kind: marker.kind,
        strong: !!marker.strong,
        start: i,
        end: i,
        next: 2,
        items: [{node, cut: marker.length}],
      }
    }
  })
  if (run) runs.push(run)

  // One "•" line is a list; one "- " or "1. " line may just be a sentence.
  return runs.filter(r => r.items.length >= 2 || r.strong)
}

// Rebuild a pasted slice with its glyph- and number-led paragraph runs as
// lists. Returns the slice untouched when there are none.
export function listifySlice(slice, schema) {
  const {bulletList, orderedList, listItem} = schema.nodes
  if (!bulletList || !orderedList || !listItem) return slice

  const nodes = []
  slice.content.forEach(node => nodes.push(node))
  const runs = listRuns(nodes)
  if (!runs.length) return slice

  const out = []
  let i = 0
  for (const run of runs) {
    while (i < run.start) out.push(nodes[i++])
    const items = run.items.map(({node, cut}) =>
      listItem.create(null, node.copy(node.content.cut(cut)))
    )
    out.push((run.kind === "ordered" ? orderedList : bulletList).create(null, items))
    i = run.end + 1
  }
  while (i < nodes.length) out.push(nodes[i++])

  // A list can't merge into the paragraph the caret is in, so a converted edge
  // closes the slice there; an untouched edge keeps its openness.
  const openStart = runs[0].start === 0 ? 0 : slice.openStart
  const openEnd = runs[runs.length - 1].end === nodes.length - 1 ? 0 : slice.openEnd
  return new Slice(Fragment.from(out), openStart, openEnd)
}

// --- Word / Outlook -------------------------------------------------------

const MSO_LEVEL = /mso-list:\s*l(\d+)\s+level(\d+)/i
// An ordered marker names a position ("1.", "a)", "iv.", "(2)"); a bullet is
// a glyph — Word's level-2 bullet is a Courier "o", which has no dot.
const MSO_ORDERED = /^\(?(\d+|[a-z]|[ivxlc]+)[.)]$/i

function msoItem(p) {
  const m = (p.getAttribute("style") || "").match(MSO_LEVEL)
  if (!m) return null
  const ignore = p.querySelector('[style*="mso-list:Ignore" i], [style*="mso-list: Ignore" i]')
  const marker = ignore ? ignore.textContent.replace(/\s+/g, "") : ""
  if (ignore) ignore.remove()
  return {p, level: Math.max(1, parseInt(m[2], 10)), ordered: MSO_ORDERED.test(marker)}
}

// Word's list paragraphs → real nested <ul>/<ol>. Everything else in the HTML
// is left as it came; ProseMirror's parser and the server sanitizer see to it.
export function listifyWordHTML(html) {
  if (!/mso-list/i.test(html)) return html

  const doc = new DOMParser().parseFromString(html, "text/html")
  // Read every item — and whether it directly follows the previous one —
  // before the DOM is touched: a run of list paragraphs is broken by
  // anything that sits between them.
  const items = []
  for (const p of doc.body.querySelectorAll("p[style]")) {
    const item = msoItem(p)
    if (!item) continue
    const last = items[items.length - 1]
    item.continues = !!last && p.previousElementSibling === last.p
    items.push(item)
  }

  let stack = [] // open lists, outermost first: {list, level, lastLi}
  for (const item of items) {
    if (!item.continues) stack = []
    while (stack.length && stack[stack.length - 1].level > item.level) stack.pop()
    let top = stack[stack.length - 1]

    if (!top || top.level < item.level) {
      const list = doc.createElement(item.ordered ? "ol" : "ul")
      if (top && top.lastLi) top.lastLi.appendChild(list)
      else item.p.before(list)
      top = {list, level: item.level, lastLi: null}
      stack.push(top)
    }

    const li = doc.createElement("li")
    const para = doc.createElement("p")
    para.append(...item.p.childNodes)
    li.appendChild(para)
    top.list.appendChild(li)
    top.lastLi = li
    item.p.remove()
  }

  return doc.body.innerHTML
}

// --- The extension --------------------------------------------------------

export const ListDetect = Extension.create({
  name: "kilnListDetect",

  addInputRules() {
    const {bulletList, orderedList} = this.editor.schema.nodes
    const rules = []
    if (bulletList) {
      rules.push(wrappingInputRule({find: new RegExp(`^\\s*([${GLYPHS}–])\\s$`), type: bulletList}))
    }
    if (orderedList) {
      rules.push(wrappingInputRule({find: /^(\d{1,3})\)\s$/, type: orderedList}))
    }
    return rules
  },

  addProseMirrorPlugins() {
    const editor = this.editor

    return [
      new Plugin({
        key: new PluginKey("kilnListDetect"),
        props: {
          transformPastedHTML: html => listifyWordHTML(html),
          transformPasted: slice =>
            // Inside a code block the text IS the content, bullets and all.
            editor.isActive("codeBlock") ? slice : listifySlice(slice, editor.schema),
        },
      }),
    ]
  },
})
