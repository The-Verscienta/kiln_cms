defmodule KilnCMSWeb.ContentEditor.MediaPickerComponents do
  @moduledoc """
  The content editor's media-library drawers (#1311): the image picker (with
  its Unsplash tab and gallery multi-select), the document picker, and the
  A/V picker that serves a video block's media, poster and caption-track
  fields. Moved verbatim from `KilnCMSWeb.ContentEditorLive`; events stay
  untargeted, so they keep landing on the enclosing LiveView.
  """

  use KilnCMSWeb, :html

  # The `phx-value-index` for a pick button: "new" inserts a fresh image block
  # (browser opened from the chrome), an integer fills that existing block.
  defp pick_index(:new), do: "new"
  defp pick_index({:gallery, _id}), do: "gallery"
  defp pick_index(:featured), do: "featured"
  defp pick_index(:seo_image), do: "seo_image"
  defp pick_index({:block, _id}), do: "block"
  defp pick_index(_), do: ""

  # The target block's stable id for a per-block pick; nil for featured/new picks
  # (so no `phx-value-bid` attribute is emitted for those).
  defp pick_block_id({:block, id}), do: id
  defp pick_block_id({:gallery, id}), do: id
  defp pick_block_id(_), do: nil
  attr :index, :any, required: true
  attr :media, :list, required: true
  attr :results, :list, default: nil
  attr :query, :string, required: true
  attr :picked, :list, default: []
  attr :unsplash_enabled?, :boolean, required: true
  attr :picker_tab, :atom, required: true
  attr :unsplash_query, :string, required: true
  attr :unsplash_photos, :list, required: true
  attr :unsplash_more?, :boolean, required: true
  attr :unsplash_searching?, :boolean, required: true
  attr :unsplash_importing, :any, required: true

  # Media-library browser as a right-side drawer (Theme D). It slides in beside the
  # editor rather than a full-screen modal that blanks the whole surface, so you
  # keep your place while choosing. Reachable from the editor chrome (insert a new
  # image block, `index = :new`), the featured-image field (`:featured`), or an
  # image block (`{:block, id}`). Browse + search + insert; while a query is active
  # `results` (a DB search) replaces the browse window.
  #
  # A second tab, gated on `@unsplash_enabled?`, searches Unsplash directly
  # (mirrors `KilnCMSWeb.MediaLive`'s own tab) so importing a stock photo
  # doesn't require a round trip through `/media` first (#487-adjacent).
  # Every picking mode gets it, including gallery multi-select — an editor
  # building a gallery should be able to pull several Unsplash photos into it
  # without leaving this drawer.
  def image_picker(assigns) do
    assigns =
      assigns
      |> assign(:visible, assigns.results || assigns.media)
      |> assign(:multi?, match?({:gallery, _id}, assigns.index))

    ~H"""
    <.modal id="image-picker-dialog" on_close="close_picker" variant={:drawer}>
      <:title>{picker_title(@index)}</:title>

      <div :if={@unsplash_enabled?} class="flex gap-1 border-b border-base-content/10 px-4 pt-3">
        <button
          type="button"
          phx-click="picker_tab"
          phx-value-tab="library"
          aria-selected={to_string(@picker_tab == :library)}
          class={[
            "px-3 py-1.5 text-sm",
            @picker_tab == :library && "border-b-2 border-primary font-medium"
          ]}
        >
          {gettext("Library")}
        </button>
        <button
          type="button"
          phx-click="picker_tab"
          phx-value-tab="unsplash"
          aria-selected={to_string(@picker_tab == :unsplash)}
          class={[
            "px-3 py-1.5 text-sm",
            @picker_tab == :unsplash && "border-b-2 border-primary font-medium"
          ]}
        >
          {gettext("Unsplash")}
        </button>
      </div>

      <div :if={@picker_tab == :library} class="flex-1 overflow-y-auto p-4">
        <form :if={@media != []} id="media-browser-filter" phx-change="search_media" class="mb-3">
          <input
            type="text"
            name="q"
            value={@query}
            placeholder={gettext("Search by filename, alt or caption")}
            aria-label={gettext("Search by filename, alt text or caption")}
            phx-debounce="150"
            autocomplete="off"
            class="w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
          />
        </form>

        <p :if={@media == []} class="text-sm text-base-content/60">
          {gettext("No media yet — upload some in the")} <.link
            navigate={~p"/media"}
            class="underline"
          >{gettext("media library")}</.link>.
        </p>
        <p :if={@media != [] and @visible == []} class="text-sm text-base-content/60">
          {gettext("No media matches “%{query}”.", query: @query)}
        </p>

        <div :if={@visible != []} class="grid grid-cols-2 gap-3 sm:grid-cols-3">
          <button
            :for={item <- @visible}
            type="button"
            phx-click={if @multi?, do: "toggle_pick", else: "pick_image"}
            phx-value-index={pick_index(@index)}
            phx-value-bid={pick_block_id(@index)}
            phx-value-id={item.id}
            phx-value-url={item.url}
            title={item.filename}
            aria-pressed={@multi? && to_string(picked_position(@picked, item.id) != nil)}
            class={[
              "group relative overflow-hidden rounded border hover:ring-2 hover:ring-primary",
              if(picked_position(@picked, item.id),
                do: "border-primary ring-2 ring-primary",
                else: "border-base-content/10"
              )
            ]}
          >
            <img
              src={item.url}
              alt={item.alt || item.filename}
              loading="lazy"
              class="aspect-square w-full object-cover"
            />
            <%!-- The number, not a tick: in a multi-select whose order becomes
                    the gallery order, "which one did I click third" is the thing
                    an editor actually needs to see. --%>
            <span
              :if={position = picked_position(@picked, item.id)}
              class="absolute right-1 top-1 flex size-6 items-center justify-center rounded-full bg-primary text-xs font-semibold text-primary-content"
            >
              {position}
            </span>
          </button>
        </div>
      </div>

      <div :if={@unsplash_enabled? and @picker_tab == :unsplash} class="flex-1 overflow-y-auto p-4">
        <form id="editor-unsplash-search" phx-submit="unsplash_search" class="flex gap-2">
          <label for="editor-unsplash-search-input" class="sr-only">
            {gettext("Search Unsplash photos")}
          </label>
          <input
            id="editor-unsplash-search-input"
            type="text"
            name="q"
            value={@unsplash_query}
            placeholder={gettext("Search Unsplash photos")}
            autocomplete="off"
            class="field-input min-w-0 flex-1"
          />
          <.button type="submit" variant="primary" phx-disable-with={gettext("Searching…")}>
            {gettext("Search")}
          </.button>
        </form>

        <p class="mt-2 text-xs text-base-content/60">
          {gettext(
            "Photos from Unsplash — importing adds a copy to your library and inserts it here."
          )}
        </p>

        <p
          :if={@unsplash_searching? and @unsplash_photos == []}
          class="mt-3 text-sm text-base-content/60"
          role="status"
        >
          {gettext("Searching…")}
        </p>

        <p
          :if={!@unsplash_searching? and @unsplash_photos == [] and @unsplash_query != ""}
          class="mt-3 text-sm text-base-content/60"
          role="status"
        >
          {gettext("No photos match “%{query}”.", query: @unsplash_query)}
        </p>

        <ul
          :if={@unsplash_photos != []}
          class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3"
          id="editor-unsplash-grid"
        >
          <li
            :for={photo <- @unsplash_photos}
            id={"editor-unsplash-#{photo.id}"}
            class="overflow-hidden rounded border border-base-content/10"
          >
            <img
              src={photo.thumb_url}
              alt={photo.alt || gettext("Unsplash photo")}
              loading="lazy"
              class="aspect-square w-full object-cover"
            />
            <div class="flex items-center justify-between gap-2 p-2">
              <p class="min-w-0 truncate text-[10px] text-base-content/70">
                <a
                  href={photo.photographer_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="hover:underline"
                >
                  {photo.photographer}
                </a>
              </p>
              <button
                type="button"
                phx-click="unsplash_import"
                phx-value-id={photo.id}
                disabled={MapSet.member?(@unsplash_importing, photo.id)}
                class="btn btn-sm btn-default shrink-0"
              >
                {if MapSet.member?(@unsplash_importing, photo.id),
                  do: gettext("Importing…"),
                  else: gettext("Import")}
              </button>
            </div>
          </li>
        </ul>

        <div :if={@unsplash_more?} class="mt-3 flex justify-center">
          <button
            type="button"
            phx-click="unsplash_load_more"
            disabled={@unsplash_searching?}
            class="btn btn-default"
          >
            {if @unsplash_searching?, do: gettext("Loading…"), else: gettext("Load more")}
          </button>
        </div>
      </div>

      <div
        :if={@multi?}
        class="flex items-center justify-between gap-3 border-t border-base-content/10 p-4"
      >
        <p class="text-sm text-base-content/70">
          {ngettext("%{count} image selected", "%{count} images selected", length(@picked))}
        </p>
        <button
          type="button"
          phx-click="add_picked_images"
          phx-value-bid={pick_block_id(@index)}
          disabled={@picked == []}
          class="rounded bg-primary px-3 py-1.5 text-sm font-medium text-primary-content disabled:opacity-40"
        >
          {gettext("Add to gallery")}
        </button>
      </div>
    </.modal>
    """
  end

  # The document counterpart of `image_picker/1` (#481) — a single-select
  # drawer over the (documents-only) file library, filling the `:file` block
  # identified by `@file_picking`. No multi-select, no "insert new from
  # chrome" shortcut, and no thumbnail grid (a badge per file instead) —
  # deliberately smaller than the image picker, since a document doesn't
  # preview the way an image does and v1 scopes to "pick from the palette,
  # then fill it in", not every entry point images have.
  attr :files, :list, required: true
  attr :results, :any, required: true
  attr :query, :string, required: true

  def file_picker(assigns) do
    assigns = assign(assigns, :visible, assigns.results || assigns.files)

    ~H"""
    <.modal id="file-picker-dialog" on_close="close_file_picker" variant={:drawer}>
      <:title>{gettext("Choose a file")}</:title>

      <div class="flex-1 overflow-y-auto p-4">
        <form
          :if={@files != []}
          id="file-browser-filter"
          phx-change="search_file_media"
          class="mb-3"
        >
          <input
            type="text"
            name="q"
            value={@query}
            placeholder={gettext("Search by filename")}
            aria-label={gettext("Search by filename")}
            phx-debounce="150"
            autocomplete="off"
            class="w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
          />
        </form>

        <p :if={@files == []} class="text-sm text-base-content/60">
          {gettext("No documents yet — upload a PDF in the")} <.link
            navigate={~p"/media"}
            class="underline"
          >{gettext("media library")}</.link>.
        </p>
        <p :if={@files != [] and @visible == []} class="text-sm text-base-content/60">
          {gettext("No documents match “%{query}”.", query: @query)}
        </p>

        <ul :if={@visible != []} class="space-y-1">
          <li :for={item <- @visible}>
            <button
              type="button"
              phx-click="pick_file"
              phx-value-id={item.id}
              title={item.filename}
              class="flex w-full items-center gap-2 rounded border border-base-content/10 px-3 py-2 text-left text-sm hover:border-primary hover:bg-base-200"
            >
              <.icon name="hero-document" class="size-5 shrink-0 text-base-content/60" />
              <span class="min-w-0 flex-1 truncate">{item.filename}</span>
              <span
                :if={item.audience != :public}
                class="shrink-0 rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-warning-ink"
              >
                {gettext("Gated")}
              </span>
            </button>
          </li>
        </ul>
      </div>
    </.modal>
    """
  end

  # The A/V counterpart of `file_picker/1` (#494), and deliberately the same
  # shape — single-select, no multi-pick, no "insert new" shortcut.
  #
  # One component covers three targets, because a video block picks from
  # three different libraries: the video/audio itself (`@av_media`), a poster
  # image (`@images`) and a WebVTT caption track (searched, since a `.vtt` is
  # rare enough not to warrant its own mounted list). `@target` is the
  # `{block_id, field}` from `@av_picking`, and it decides both the list shown
  # and the copy — a drawer titled "Choose a video" that is actually offering
  # poster images is worse than no drawer.
  attr :target, :any, required: true
  attr :items, :list, required: true
  attr :images, :list, required: true
  attr :results, :any, required: true
  attr :query, :string, required: true

  def av_picker(assigns) do
    {_bid, field} = assigns.target

    mounted =
      case field do
        "poster" -> assigns.images
        # No mounted list for caption tracks: `@results` (the search) is the
        # only way to reach one, and an empty state below says so.
        "captions" -> []
        _media -> assigns.items
      end

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:mounted, mounted)
      |> assign(:visible, assigns.results || mounted)

    ~H"""
    <.modal id="av-picker-dialog" on_close="close_av_picker" variant={:drawer}>
      <:title>{av_picker_title(@field)}</:title>

      <div class="flex-1 overflow-y-auto p-4">
        <form id="av-browser-filter" phx-change="search_av_media" class="mb-3">
          <input
            type="text"
            name="q"
            value={@query}
            placeholder={gettext("Search by filename")}
            aria-label={gettext("Search by filename")}
            phx-debounce="150"
            autocomplete="off"
            class="w-full rounded border border-base-content/20 bg-transparent px-3 py-1.5 text-sm"
          />
        </form>

        <p :if={@visible == [] and @query != ""} class="text-sm text-base-content/60">
          {gettext("Nothing matches “%{query}”.", query: @query)}
        </p>
        <p :if={@visible == [] and @query == ""} class="text-sm text-base-content/60">
          {av_picker_empty(@field)} <.link navigate={~p"/media"} class="underline">{gettext(
                "media library"
              )}</.link>.
        </p>

        <ul :if={@visible != []} class="space-y-1">
          <li :for={item <- @visible}>
            <button
              type="button"
              phx-click="pick_av"
              phx-value-id={item.id}
              title={item.filename}
              class="flex w-full items-center gap-2 rounded border border-base-content/10 px-3 py-2 text-left text-sm hover:border-primary hover:bg-base-200"
            >
              <.icon
                name={av_item_icon(item)}
                class="size-5 shrink-0 text-base-content/60"
              />
              <span class="min-w-0 flex-1 truncate">{item.filename}</span>
              <span :if={av_item_duration(item)} class="shrink-0 text-xs text-base-content/60">
                {av_item_duration(item)}
              </span>
              <span
                :if={Map.get(item, :audience, :public) != :public}
                class="shrink-0 rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-warning-ink"
              >
                {gettext("Gated")}
              </span>
            </button>
          </li>
        </ul>
      </div>
    </.modal>
    """
  end

  defp av_picker_title("poster"), do: gettext("Choose a poster image")
  defp av_picker_title("captions"), do: gettext("Choose a caption track")
  defp av_picker_title(_field), do: gettext("Choose a video or audio file")

  defp av_picker_empty("poster"), do: gettext("No images yet — upload one in the")

  defp av_picker_empty("captions"),
    do: gettext("Search for a WebVTT (.vtt) track you've uploaded to the")

  defp av_picker_empty(_field),
    do: gettext("No video or audio yet — upload an MP4, WebM, MP3 or M4A in the")

  # The picker lists items from three different `select:`s, so nothing here may
  # assume a field is loaded — `Map.get/3` throughout.
  defp av_item_icon(item) do
    case KilnCMS.MediaKind.of(Map.get(item, :content_type)) do
      :video -> "hero-film"
      :audio -> "hero-musical-note"
      :captions -> "hero-language"
      _kind -> "hero-photo"
    end
  end

  defp av_item_duration(item),
    do: KilnCMS.MediaKind.humanize_duration(Map.get(item, :duration_seconds))

  # 1-based position of a media id in the current selection, or nil.
  defp picked_position(picked, id) do
    case Enum.find_index(picked, &(&1.id == id)) do
      nil -> nil
      index -> index + 1
    end
  end

  # Drawer heading, per open mode.
  defp picker_title(:new), do: gettext("Insert an image")
  defp picker_title({:gallery, _id}), do: gettext("Add images to the gallery")
  defp picker_title(:featured), do: gettext("Featured image")
  defp picker_title(:seo_image), do: gettext("Choose a social image")
  defp picker_title(_), do: gettext("Choose an image")
end
