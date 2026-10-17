// The client half of the content editor's reference picker (R9,
// `KilnCMSWeb.ContentEditor.ReferencePicker`). The server owns the search,
// the results and the value; this adds what a round trip can't do well:
//
//   * the WAI-ARIA combobox keys on the search input — Down/Up move through
//     the options (`aria-activedescendant`, focus stays in the input), Enter
//     picks, Escape and Tab close. Enter never reaches the editor form, so it
//     can't submit a save by accident;
//   * focus after a pick or a removal, which would otherwise fall to <body>
//     when the control that had it is re-rendered away;
//   * the "Add new" form's keys — it renders inside the editor form, so Enter
//     in one of its inputs would save the document; it presses "Create and
//     connect" instead, and Escape presses Cancel;
//   * drag-to-reorder of a list's rows (SortableJS, as the gallery block's
//     `GallerySortable`). Dragging is an enhancement: every row also has
//     move up/down buttons, so a pointer is never the only way to reorder.
//
// The hook sits on the component's root, so `pushEventTo(this.el, …)` lands
// on the component, not the editor.
import Sortable from "../vendor/sortable"

export const ReferencePicker = {
  mounted() {
    this.active = -1
    this.pending = null
    this.onKey = e => this.key(e)
    this.onInput = e => {
      if (e.target.matches("[data-ref-search]")) this.active = -1
    }
    // Capture, so the note is taken before LiveView handles the click.
    this.onClick = e => this.noteFocus(e.target)
    this.el.addEventListener("keydown", this.onKey)
    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("click", this.onClick, true)
    this.setupSorter()
  },

  updated() {
    this.setupSorter()
    this.highlight()
    this.restoreFocus()
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKey)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("click", this.onClick, true)
    this.sorter && this.sorter.destroy()
  },

  search() {
    return this.el.querySelector("[data-ref-search]")
  },

  options() {
    return Array.from(this.el.querySelectorAll("[data-ref-option]"))
  },

  rows() {
    return Array.from(this.el.querySelectorAll("[data-ref-items] > li"))
  },

  isOpen() {
    return this.search()?.getAttribute("aria-expanded") === "true"
  },

  key(e) {
    if (e.target.closest("[data-ref-new]")) return this.newFormKey(e)

    const input = e.target.closest("[data-ref-search]")
    if (!input) return

    switch (e.key) {
      case "ArrowDown":
        e.preventDefault()
        if (this.isOpen()) this.move(1)
        else this.pushEventTo(this.el, "ref_open", {})
        break
      case "ArrowUp":
        e.preventDefault()
        if (this.isOpen()) this.move(-1)
        break
      case "Enter": {
        // Never the editor form's submit, whether or not an option is active.
        e.preventDefault()
        const option = this.options()[this.active]
        if (this.isOpen() && option) option.click()
        break
      }
      case "Escape":
        if (this.isOpen()) {
          e.preventDefault()
          e.stopPropagation()
          this.active = -1
          this.pushEventTo(this.el, "ref_close", {})
        }
        break
      case "Tab":
        if (this.isOpen()) this.pushEventTo(this.el, "ref_close", {})
        break
    }
  },

  newFormKey(e) {
    const form = e.target.closest("[data-ref-new]")

    if (e.key === "Enter" && e.target.matches("input")) {
      e.preventDefault()
      form.querySelector("[data-ref-new-submit]")?.click()
    } else if (e.key === "Escape") {
      e.preventDefault()
      e.stopPropagation()
      form.querySelector("[data-ref-new-cancel]")?.click()
    }
  },

  move(delta) {
    const count = this.options().length
    if (count === 0) return
    this.active = this.active === -1 && delta < 0 ? count - 1 : (this.active + delta + count) % count
    this.highlight()
  },

  // Re-applied after every patch: the server renders every option
  // `aria-selected="false"`, so a patch would otherwise clear the highlight.
  highlight() {
    const input = this.search()
    const options = this.options()
    if (this.active >= options.length) this.active = options.length - 1

    options.forEach((option, i) => option.setAttribute("aria-selected", String(i === this.active)))

    const active = options[this.active]
    if (input && active) {
      input.setAttribute("aria-activedescendant", active.id)
      active.scrollIntoView({block: "nearest"})
    } else if (input) {
      input.removeAttribute("aria-activedescendant")
    }
  },

  // A pick adds a row and a removal takes one away; either can re-render the
  // focused control out of existence. Note which, and the row count it
  // started from, so focus is placed once the rows have actually changed —
  // the component re-renders once on its own before the editor's edit lands.
  noteFocus(target) {
    const rows = this.rows()

    if (target.closest("[data-ref-option]") && !target.closest(`#${this.el.id}-more`)) {
      // The options change under a pick, so the highlight starts over.
      this.active = -1
      this.pending = {kind: "pick", count: rows.length}
    } else if (target.closest("[data-ref-new-submit]")) {
      // A created record lands as a row, like a pick.
      this.pending = {kind: "pick", count: rows.length}
    } else if (target.closest("[data-ref-new-cancel]")) {
      this.pending = {kind: "cancel"}
    } else if (target.closest("[data-ref-remove]")) {
      const index = rows.indexOf(target.closest("li"))
      this.pending = {kind: "remove", count: rows.length, index}
    } else {
      return
    }

    clearTimeout(this.pendingTimer)
    this.pendingTimer = setTimeout(() => (this.pending = null), 3000)
  },

  restoreFocus() {
    const pending = this.pending
    const rows = this.rows()

    // Cancel closes the form without touching the rows: back to "Add new".
    if (pending?.kind === "cancel") {
      this.pending = null
      ;(this.el.querySelector(`#${this.el.id}-new button`) || this.search())?.focus()
      return
    }

    if (!pending || rows.length === pending.count) return
    this.pending = null

    const removes = rows.map(row => row.querySelector("[data-ref-remove]")).filter(Boolean)
    const input = this.search()

    if (pending.kind === "pick") {
      // A list keeps its input for the next pick; a single reference's input
      // gives way to the row, so its remove button takes focus.
      ;(input || removes[removes.length - 1])?.focus()
    } else {
      const next = removes[Math.min(pending.index, removes.length - 1)]
      ;(next || input)?.focus()
    }
  },

  setupSorter() {
    const list = this.el.querySelector("[data-ref-items]")
    if (list === this.list) return

    this.sorter && this.sorter.destroy()
    this.sorter = null
    this.list = list
    if (!list) return

    this.sorter = Sortable.create(list, {
      animation: 150,
      handle: "[data-drag-handle]",
      ghostClass: "opacity-40",
      onEnd: () => {
        const order = Array.from(list.children)
          .map(row => row.dataset.sortId)
          .filter(id => id !== undefined)
        this.pushEventTo(this.el, "ref_reorder", {order})
      },
    })
  },
}
