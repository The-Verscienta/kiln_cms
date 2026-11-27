// A backup file's download (part of #2225), started by the Backups page.
//
// The page mints a one-minute token on click (`KilnCMSWeb.BackupLive`'s
// "download" event) and pushes it here. The hook posts it, with the page's
// CSRF token, in a form it builds and removes at once: a POST body, never a
// URL, so the token stays out of logs, history and the downloads list. The
// answer is an `attachment`, so the page stays where it is; a refusal is a
// short plain-text page saying why.

const ACTION = "/editor/backups/download"

export function downloadForm(doc, {action, token}, csrfToken) {
  if (action !== ACTION || typeof token !== "string" || token === "") return null
  if (typeof csrfToken !== "string" || csrfToken === "") return null

  const form = doc.createElement("form")
  form.method = "post"
  form.action = ACTION
  form.hidden = true

  for (const [name, value] of [["_csrf_token", csrfToken], ["token", token]]) {
    const input = doc.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    form.appendChild(input)
  }

  return form
}

export const BackupDownload = {
  mounted() {
    this.handleEvent("kiln:backup-download", (payload) => {
      const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
      const form = downloadForm(document, payload || {}, csrf)
      if (!form) return

      document.body.appendChild(form)
      form.submit()
      form.remove()
    })
  },
}
