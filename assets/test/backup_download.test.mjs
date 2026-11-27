// The form the Backups page posts a download token with (part of #2225),
// against a fake document. Run: `npm test` in assets/.
import {test} from "node:test"
import assert from "node:assert/strict"

import {downloadForm} from "../js/backup_download.js"

const fakeDocument = () => ({
  createElement(tag) {
    return {tag, children: [], appendChild(child) { this.children.push(child) }}
  },
})

const fields = form => Object.fromEntries(form.children.map(i => [i.name, [i.type, i.value]]))

test("posts the token and the CSRF token to the download route, hidden", () => {
  const form = downloadForm(fakeDocument(), {action: "/editor/backups/download", token: "T"}, "C")

  assert.equal(form.tag, "form")
  assert.equal(form.method, "post")
  assert.equal(form.action, "/editor/backups/download")
  assert.equal(form.hidden, true)
  assert.deepEqual(fields(form), {_csrf_token: ["hidden", "C"], token: ["hidden", "T"]})
})

test("builds nothing for another action, a missing token or no CSRF token", () => {
  const doc = fakeDocument()

  for (const [payload, csrf] of [
    [{action: "https://evil.example/x", token: "T"}, "C"],
    [{action: "/editor/backups/download/../../x", token: "T"}, "C"],
    [{action: "/editor/backups/download"}, "C"],
    [{action: "/editor/backups/download", token: ""}, "C"],
    [{action: "/editor/backups/download", token: "T"}, undefined],
    [{}, "C"],
  ]) {
    assert.equal(downloadForm(doc, payload, csrf), null, JSON.stringify(payload))
  }
})
