// The WAI-ARIA tabs keyboard model on a server-driven tablist (#1680, #1679).
//
// Attach with `phx-hook="TabKeys"` on a kit `.tabs` element carrying
// `role="tablist"` (and an `id`, as every hook needs). Its `role="tab"`
// buttons keep their own `phx-click`; this only adds the keys:
// Left/Right move to the neighbouring tab (wrapping), Home/End to the ends,
// and the tab is activated as it is focused. Tab itself leaves the list —
// only the selected tab is in the tab order (the server renders
// `tabindex="0"` on it and `-1` on the rest).
//
// Shared by the Form Builder's section switcher and the content editor's
// inspector rail. It started as a colocated hook in form_builder_live.ex,
// but a colocated hook is namespaced to the module that declares it, so a
// second tablist could not reach it.
export const TabKeys = {
  mounted() {
    this.el.addEventListener("keydown", e => {
      const tabs = Array.from(this.el.querySelectorAll('[role="tab"]'))
      const i = tabs.indexOf(document.activeElement)
      if (i === -1) return
      const next = {
        ArrowRight: (i + 1) % tabs.length,
        ArrowLeft: (i - 1 + tabs.length) % tabs.length,
        Home: 0,
        End: tabs.length - 1,
      }[e.key]
      if (next === undefined) return
      e.preventDefault()
      tabs[next].focus()
      tabs[next].click()
    })
  },
}
