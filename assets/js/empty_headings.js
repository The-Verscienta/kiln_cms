// Marks an empty top-level heading so the author can see it (#1728).
//
// An H2 picked from the slash menu and never typed into — or one whose text
// was deleted — renders as an ordinary blank line, yet the accessibility and
// SEO panels flag it ("1 heading has no text — block n"). This decorates such
// a heading with `is-empty-heading` + `data-level`, which app.css turns into a
// dashed rule and a faint "H2" label.
//
// "Empty" is the advisory's own test, not a guess from the DOM:
// `Kiln.Advisory.Body` trims the heading's text (a hard break is "\n" there),
// and advisory_jump.js's `blank()` trims `textContent`. So a heading holding
// only spaces or only a Shift+Enter break is marked too. Only top-level
// headings: one inside a blockquote, list item or table cell is flattened to
// text by the Portable Text conversion and never reaches the advisory.
import {Extension} from "@tiptap/core"
import {Plugin, PluginKey} from "@tiptap/pm/state"
import {Decoration, DecorationSet} from "@tiptap/pm/view"

export const EmptyHeadings = Extension.create({
  name: "kilnEmptyHeadings",

  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: new PluginKey("kilnEmptyHeadings"),
        props: {
          decorations(state) {
            const marks = []
            state.doc.forEach((node, pos) => {
              if (node.type.name === "heading" && node.textContent.trim() === "") {
                marks.push(
                  Decoration.node(pos, pos + node.nodeSize, {
                    class: "is-empty-heading",
                    "data-level": String(node.attrs.level),
                  }),
                )
              }
            })
            return marks.length ? DecorationSet.create(state.doc, marks) : DecorationSet.empty
          },
        },
      }),
    ]
  },
})
