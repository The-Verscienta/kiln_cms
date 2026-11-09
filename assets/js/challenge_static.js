// The embedded form's human-verification widget (#2249).
//
// The embed iframe (`/forms/:slug/embed`) does not load app.js — it is framed
// on someone else's page and carries nothing it does not need — so its widget
// is mounted by this, built as its own small bundle (the `kiln_challenge_embed`
// esbuild profile) and loaded by a `<script type="module" src>` next to the
// widget. Never an inline script: the embed policy is `script-src 'self'`
// plus the provider's origin.
import {mountAllWhenReady} from "./challenge"

mountAllWhenReady()
