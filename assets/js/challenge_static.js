// The script the embed iframe loads instead of app.js (#2249), and the one a
// page with a conditional form loads beside its own (#2262).
//
// The embed iframe (`/forms/:slug/embed`) does not load app.js — it is framed
// on someone else's page and carries nothing it does not need — so its widget
// is mounted by this, built as its own small bundle (the `kiln_challenge_embed`
// esbuild profile) and loaded by a `<script type="module" src>` next to the
// widget. Never an inline script: the embed policy is `script-src 'self'`
// plus the provider's origin.
//
// A form with a condition loads it too, wherever it is drawn
// (`KilnCMSWeb.BlockComponents.public_form/1`), so public.js stays as small
// as it was on every other page. Both mounts are idempotent: on a page that
// also runs public.js or app.js, the widget is mounted once.
import {mountAllWhenReady} from "./challenge"
import {enhanceFormsWhenReady} from "./form_enhance"

mountAllWhenReady()
enhanceFormsWhenReady()
