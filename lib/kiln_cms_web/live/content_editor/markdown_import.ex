defmodule KilnCMSWeb.ContentEditor.MarkdownImport do
  @moduledoc """
  Markdown into the content editor, three ways — all through
  `KilnCMS.Markdown`, so the editor, the API's `body_markdown` and any other
  publisher produce the same blocks from the same text:

    * **Paste** into a rich-text block. The block's TipTap extension
      (`assets/js/markdown_paste.js`) spots Markdown-shaped plain text and
      asks for it here as a TipTap document (`"markdown_paste"`, replied to),
      then inserts it as one editor transaction with a "Pasted as Markdown —
      Undo · Paste as plain text" notice.
    * **Drop** a `.md` file on a rich-text block — the same round trip.
    * **Import** a `.md` file as the document body (`"markdown_import"`): the
      file is parsed here and held until the author confirms, in a dialog
      that says what will change — the block count, and the title, slug and
      excerpt the file supplies (each can be unticked) — and whether it
      replaces the existing blocks or follows them. Applying it is a form
      write, so `"markdown_import_apply"` is handled by the LiveView itself
      (through `apply_import/2`), next to the slug derivation an imported
      title has to go through.

  Every event is gated on `@may_write?`, the editor's own write gate; the
  record's policies re-check the eventual save.

  Attached as an `on_mount` lifecycle hook, like
  `KilnCMSWeb.ContentEditor.BlockOps`.
  """
  use KilnCMSWeb, :html

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  import KilnCMSWeb.ContentEditor.BlockParams,
    only: [blocks_count: 1, full_blocks_input: 1, inject_rich_bodies: 2]

  alias KilnCMS.Markdown
  alias Phoenix.LiveView.ColocatedHook

  @fields ~w(title slug excerpt)

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:markdown_import, nil)
     |> attach_hook(:editor_markdown, :handle_event, &on_event/3)}
  end

  # ── Events ────────────────────────────────────────────────────────────────

  # Prose only: the reply is inserted INTO the block the author pasted in, so
  # an image becomes a link to it rather than a block of its own (see
  # `KilnCMS.Markdown.to_tiptap/1`). A refusal replies too — the client then
  # pastes the text as it came, rather than swallowing it.
  defp on_event("markdown_paste", %{"text" => text}, socket) when is_binary(text) do
    cond do
      not writable?(socket) -> {:halt, %{error: "forbidden"}, socket}
      byte_size(text) > Markdown.max_bytes() -> {:halt, %{error: "too_large"}, socket}
      not String.valid?(text) -> {:halt, %{error: "not_text"}, socket}
      true -> {:halt, %{doc: Markdown.to_tiptap(text)}, socket}
    end
  end

  defp on_event("markdown_paste", _params, socket),
    do: {:halt, %{error: "malformed"}, socket}

  defp on_event("markdown_import", params, socket) do
    if writable?(socket), do: {:halt, receive_file(socket, params)}, else: {:halt, socket}
  end

  defp on_event("markdown_import_toggle", %{"field" => field}, socket) when field in @fields do
    case socket.assigns.markdown_import do
      %{apply: apply} = pending ->
        apply =
          if MapSet.member?(apply, field),
            do: MapSet.delete(apply, field),
            else: MapSet.put(apply, field)

        {:halt, assign(socket, :markdown_import, %{pending | apply: apply})}

      nil ->
        {:halt, socket}
    end
  end

  defp on_event("markdown_import_cancel", _params, socket),
    do: {:halt, assign(socket, :markdown_import, nil)}

  defp on_event(_event, _params, socket), do: {:cont, socket}

  defp writable?(socket), do: socket.assigns[:may_write?] == true

  defp receive_file(socket, %{"too_large" => _}), do: too_large(socket)

  defp receive_file(socket, %{"text" => text} = params) when is_binary(text) do
    cond do
      byte_size(text) > Markdown.max_bytes() ->
        too_large(socket)

      not String.valid?(text) ->
        put_flash(socket, :error, gettext("That file isn't UTF-8 text, so it can't be imported."))

      true ->
        doc = Markdown.parse_document(text)

        if doc.blocks == [] and is_nil(doc.title) do
          put_flash(socket, :error, gettext("That file has nothing in it to import."))
        else
          assign(socket, :markdown_import, pending(doc, params["name"], socket))
        end
    end
  end

  defp receive_file(socket, _params), do: socket

  defp too_large(socket) do
    put_flash(
      socket,
      :error,
      gettext("That file is too large to import (the limit is %{size} MB).",
        size: div(Markdown.max_bytes(), 1_000_000)
      )
    )
  end

  # What the dialog shows and `apply_import/2` writes. A field the file does
  # not supply is absent; one it does supply is ticked — the author chose this
  # file, and the dialog shows each value next to its box.
  defp pending(doc, name, socket) do
    values =
      %{"title" => doc.title, "slug" => doc.slug, "excerpt" => doc.excerpt}
      |> Map.reject(fn {field, value} ->
        is_nil(value) or (field == "excerpt" and socket.assigns[:has_excerpt] != true)
      end)

    %{
      name: file_name(name),
      blocks: doc.blocks,
      values: values,
      apply: values |> Map.keys() |> MapSet.new()
    }
  end

  defp file_name(name) when is_binary(name) and name != "", do: Path.basename(name)
  defp file_name(_name), do: gettext("Markdown file")

  # ── Applying an import ────────────────────────────────────────────────────

  @doc """
  Apply the pending import to the editor form: `"replace"` swaps every block
  for the file's, `"append"` adds the file's after them. Returns the params
  to validate (every block, plus any title/slug/excerpt the author kept
  ticked), the form field the LiveView's slug sync should treat as edited,
  and the socket with the new block forms and the import cleared. `:error`
  when there is nothing pending or the editor can't write.

  New blocks are added as sub-forms (`AshPhoenix.Form.add_form/3`, as
  `add_block` does) rather than by validating a longer list: a params entry
  that matches no sub-form is otherwise matched by POSITION and inherits
  another block's type.
  """
  @spec apply_import(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:ok, map(), [String.t()] | nil, Phoenix.LiveView.Socket.t()} | :error
  def apply_import(socket, mode) when mode in ["replace", "append"] do
    with %{} = pending <- socket.assigns.markdown_import,
         true <- writable?(socket) do
      {params, target, socket} = do_apply(socket, pending, mode)
      {:ok, params, target, socket}
    else
      _ -> :error
    end
  end

  def apply_import(_socket, _mode), do: :error

  defp do_apply(socket, pending, mode) do
    replace? = mode == "replace"
    base = if replace?, do: remove_all_blocks(socket.assigns.form), else: socket.assigns.form
    added = Enum.map(pending.blocks, &block_params/1)

    form =
      Enum.reduce(added, base, fn params, form ->
        AshPhoenix.Form.add_form(form, form.name <> "[blocks]", params: params)
      end)

    # Each imported prose body is registered as its block's pending body: a
    # rich-text block's DOM carries no body field, so the server-held copy is
    # what a save injects (`inject_rich_bodies/2`) — without it the next Save
    # would store the new blocks empty. A replaced document's pending bodies
    # (keyed by the removed blocks' ids, or before a first save by POSITION,
    # which the new blocks would inherit) and its columns' children go with
    # the blocks they belonged to.
    {kept_bodies, block_children} =
      if replace?,
        do: {%{}, %{}},
        else: {socket.assigns.rich_bodies, socket.assigns.block_children}

    rich_bodies =
      Map.merge(
        kept_bodies,
        for(
          %{"_union_type" => "rich_text", "id" => id, "body" => body} <- added,
          into: %{},
          do: {id, body}
        )
      )

    chosen = Map.take(pending.values, MapSet.to_list(pending.apply))

    params =
      form
      |> AshPhoenix.Form.params()
      |> Map.put("blocks", full_blocks_input(form))
      |> inject_rich_bodies(rich_bodies)
      |> Map.merge(chosen)

    socket =
      socket
      |> assign(:form, form)
      |> assign(:rich_bodies, rich_bodies)
      |> assign(:block_children, block_children)
      |> assign(:markdown_import, nil)
      |> put_flash(
        :info,
        ngettext(
          "Imported %{count} block from %{name}.",
          "Imported %{count} blocks from %{name}.",
          length(pending.blocks),
          name: pending.name
        )
      )

    {params, slug_target(chosen), socket}
  end

  # The field the LiveView's `sync_slug/3` should treat as just edited: a
  # supplied slug pins itself (as typing one does), and an imported title
  # re-derives an unpinned slug (as typing one does).
  defp slug_target(%{"slug" => _}), do: ["form", "slug"]
  defp slug_target(%{"title" => _}), do: ["form", "title"]
  defp slug_target(_chosen), do: nil

  defp remove_all_blocks(form) do
    case blocks_count(form) do
      0 ->
        form

      count ->
        Enum.reduce((count - 1)..0//-1, form, fn index, acc ->
          AshPhoenix.Form.remove_form(acc, "#{acc.name}[blocks][#{index}]")
        end)
    end
  end

  # `KilnCMS.Blocks.Html`'s `%{"type", "value"}` input shape → the editor's
  # union sub-form params, with the stable id every editor block carries.
  defp block_params(%{"type" => type, "value" => value}),
    do: Map.merge(value, %{"_union_type" => type, "id" => Ash.UUID.generate()})

  # ── Components ────────────────────────────────────────────────────────────

  @doc """
  The "Import Markdown" button. It opens the hidden file input rendered by
  `import_dialog/1` — which lives outside the editor `<form>` (a file input
  inside it would fire the form's `phx-change`), so this is a button that
  asks that input to open rather than a `<label>`, which a keyboard can't
  reach.
  """
  def import_button(assigns) do
    ~H"""
    <button
      type="button"
      id="markdown-import-button"
      phx-click={JS.dispatch("kiln:markdown-pick", to: "#markdown-import-file")}
      class="btn btn-sm btn-ghost"
      title={gettext("Replace or extend this document's blocks with a Markdown (.md) file")}
    >
      <.icon name="hero-document-arrow-up" class="mr-1 size-4" />{gettext("Import Markdown")}
    </button>
    """
  end

  attr :pending, :map, default: nil
  attr :existing, :integer, required: true
  attr :may_write?, :boolean, required: true

  @doc "The hidden `.md` file input and, while an import is pending, its confirmation dialog."
  def import_dialog(assigns) do
    ~H"""
    <input
      :if={@may_write?}
      id="markdown-import-file"
      type="file"
      accept=".md,.markdown,.mdown,.mkd,.txt,text/markdown,text/plain"
      class="hidden"
      phx-hook=".MarkdownFile"
      data-max-bytes={KilnCMS.Markdown.max_bytes()}
    />
    <script :type={ColocatedHook} name=".MarkdownFile">
      // Reads the chosen file in the browser and sends its TEXT: the server
      // parses and holds it, and nothing is written until the author confirms
      // in the dialog. Over the limit, only the fact is sent — the server
      // owns the message.
      export default {
        mounted() {
          this.pick = () => this.el.click()
          this.el.addEventListener("kiln:markdown-pick", this.pick)
          this.el.addEventListener("change", () => {
            const file = this.el.files && this.el.files[0]
            // Cleared at once so choosing the same file again still fires.
            this.el.value = ""
            if (!file) return
            if (file.size > Number(this.el.dataset.maxBytes)) {
              this.pushEvent("markdown_import", {name: file.name, too_large: true})
              return
            }
            file.text().then(text => this.pushEvent("markdown_import", {name: file.name, text}))
          })
        },
        destroyed() {
          this.el.removeEventListener("kiln:markdown-pick", this.pick)
        },
      }
    </script>

    <div
      :if={@pending}
      id="markdown-import-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      phx-window-keydown="markdown_import_cancel"
      phx-key="Escape"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="markdown-import-heading"
        class="w-full max-w-lg rounded-lg border border-base-content/10 bg-base-100 p-6 shadow-xl"
      >
        <h2 id="markdown-import-heading" class="text-lg font-medium">
          {gettext("Import %{name}", name: @pending.name)}
        </h2>
        <p class="mt-1 text-sm text-base-content/70">
          {ngettext(
            "The file converts to %{count} block.",
            "The file converts to %{count} blocks.",
            length(@pending.blocks)
          )}
        </p>

        <fieldset :if={@pending.values != %{}} class="mt-4 space-y-2 text-sm">
          <legend class="mb-1 font-medium">{gettext("Also set, from the file")}</legend>
          <label :for={{field, value} <- rows(@pending)} class="flex items-start gap-2">
            <input
              type="checkbox"
              id={"markdown-import-#{field}"}
              phx-click="markdown_import_toggle"
              phx-value-field={field}
              checked={MapSet.member?(@pending.apply, field)}
              class="mt-0.5"
            />
            <span>
              <span class="font-medium">{field_label(field)}</span>
              <span class="break-all text-base-content/70">{value}</span>
            </span>
          </label>
        </fieldset>

        <p :if={@existing > 0} class="mt-4 text-sm text-base-content/70">
          {ngettext(
            "This document already has %{count} block.",
            "This document already has %{count} blocks.",
            @existing
          )}
        </p>

        <div class="mt-6 flex flex-wrap justify-end gap-2">
          <button type="button" phx-click="markdown_import_cancel" class="btn btn-sm btn-ghost">
            {gettext("Cancel")}
          </button>
          <button
            :if={@existing > 0}
            type="button"
            phx-click="markdown_import_apply"
            phx-value-mode="append"
            class="btn btn-sm btn-default"
          >
            {gettext("Add after existing blocks")}
          </button>
          <button
            type="button"
            phx-click="markdown_import_apply"
            phx-value-mode="replace"
            class="btn btn-sm btn-primary"
          >
            {if @existing > 0, do: gettext("Replace existing blocks"), else: gettext("Import")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp rows(pending), do: for(field <- @fields, value = pending.values[field], do: {field, value})

  defp field_label("title"), do: gettext("Title")
  defp field_label("slug"), do: gettext("Slug")
  defp field_label("excerpt"), do: gettext("Excerpt")
end
