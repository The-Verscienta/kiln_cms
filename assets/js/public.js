// The script for signed-out content pages (#2402): delivered pages and posts,
// the blog and event indexes, search, a form's own page and its thank-you and
// refused re-render, the newsletter pages. Built by the `kiln_public` esbuild
// profile; `KilnCMSWeb.Layouts.js_bundle_path/1` picks it over app.js for a
// controller that opts in, and only on a dead render with no flash.
//
// Those pages are plain HTML with no LiveView, so this carries only what they
// use from app.js. Keep it that way: no LiveView or Phoenix socket, no console
// code, no editor dependency. `mix kiln.assets.budget` refuses a build that
// pulls any of them in, and fails if `js/challenge.js` drops out.
//
// Something a public page needs from here must work on a dead render: no
// hooks, no `phx-*` bindings, no JS commands.

// `data-method` / `data-confirm` links and buttons. No delivered template uses
// them today; this is the same safety net app.js carries.
import "phoenix_html"
import {mountAllWhenReady} from "./challenge"
import {initSearchShortcut} from "./search_shortcut"

// Human verification on public forms (#2249): every `data-kiln-challenge`
// widget on the page — see `mountAll` in assets/js/challenge.js.
mountAllWhenReady()

// ⌘K / Ctrl-K takes an editor reading the site to the console's search.
initSearchShortcut()
