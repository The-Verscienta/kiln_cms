// The body's picture door (texttile's uploads.js, adapted to LiveView uploads).
//
// A rich-text block that receives image files (paste or drop — see the
// ImageFiles plugin in rich_text.js) does not upload them itself: it raises
// one `kiln:body-files` event with the files and its own block id, and this
// hook, mounted once around the form's hidden `live_file_input`, hands them to
// LiveView's uploader. The queue, the progress, the size and type checks and
// the retry-free failure state are all LiveView's; the placeholder in the
// block list is server-rendered from the upload entries.
//
// Two things happen here that LiveView cannot do on its own:
//
//   * The anchor. An upload entry carries a name and bytes, not the block it
//     was dropped on, so that goes up first as `body_images_anchor`, keyed by
//     file name. Both pushes ride the same channel in order.
//   * Unique names. Every picture pasted from the clipboard arrives as
//     "image.png", and the anchor map is keyed by name — so a file whose name
//     this page has already sent gets a "-2" before it goes.
export const BodyImageUploader = {
  mounted() {
    this.seen = new Set()
    this.onFiles = e => {
      const {files, after} = e.detail || {}
      if (files && files.length) this.send(files, after || null)
    }
    document.addEventListener("kiln:body-files", this.onFiles)
  },

  destroyed() {
    document.removeEventListener("kiln:body-files", this.onFiles)
  },

  send(files, after) {
    const renamed = Array.from(files).map(
      f => new File([f], this.uniqueName(f), {type: f.type, lastModified: f.lastModified})
    )
    this.pushEvent("body_images_anchor", {after, names: renamed.map(f => f.name)})
    this.upload("body_images", renamed)
  },

  uniqueName(file) {
    // Brackets and parentheses would only ever confuse a name shown in
    // markup-ish places; nothing else about the name is touched.
    const raw = (file.name || "pasted-image.png").replace(/[[\]()]/g, "")
    const dot = raw.lastIndexOf(".")
    const base = dot > 0 ? raw.slice(0, dot) : raw
    const ext = dot > 0 ? raw.slice(dot) : ""
    let name = raw
    let i = 2
    while (this.seen.has(name)) name = `${base}-${i++}${ext}`
    this.seen.add(name)
    return name
  },
}
