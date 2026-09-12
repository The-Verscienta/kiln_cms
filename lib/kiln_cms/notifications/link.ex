defmodule KilnCMS.Notifications.Link do
  @moduledoc """
  Where a notification points — one place, for all three channels (#1320).

  A notification names its subject as `content_type` + `content_id` + an
  optional `block_id` (see `KilnCMS.Notifications.Notification`). This turns
  that trio into the console link: `path/1` for the in-app bell and inbox,
  `url/1` for the email, which needs an absolute one.

  ## The block anchor is a query param, not a fragment

  A block-anchored notification (a comment thread, a task on a paragraph)
  links to `?comment=<block_id>`, which `ContentEditorLive` reads at mount to
  open that block's thread — the same deep link the shared preview's comment
  pins use (#802), and the reason this module exists rather than a `#block-…`
  fragment.

  There is no fragment to aim at. `KilnCMS.HeadingAnchors` adds `id`
  attributes in `ContentController.blocks/3` only, for **public** delivery; the
  editor and the LiveView previews are deliberately id-less so one page can
  render the same block twice without minting duplicate ids (#1439). What the
  editor's own block cards carry is `id="block-<index>"` — positional, so it
  moves when a block moves and is no use as a stored anchor. The query param is
  the only durable console anchor, and it is also the better one: it opens the
  thread panel rather than merely scrolling near it.

  ## `nil` block

  A document-level event (published, returned to draft, a task on the whole
  record) has no `block_id` and links to the document.

  ## Named `editor_path` / `editor_url`, not `path` / `url`

  `Phoenix.VerifiedRoutes` imports `path/2,3` and `url/2,3` as macros, and an
  imported macro wins over a same-name local function — a `path/3` here would
  silently expand to the route macro and fail to compile. The longer names are
  also what the mail workers' own private helpers were already called.
  """
  use KilnCMSWeb, :verified_routes

  @typedoc "Anything carrying the anchor trio — a `Notification`, a `Task`, or a plain map."
  @type subject :: %{
          required(:content_type) => String.t(),
          required(:content_id) => String.t(),
          optional(:block_id) => String.t() | nil
        }

  @doc """
  The console path for a notification's subject.

      iex> KilnCMS.Notifications.Link.editor_path(%{content_type: "post", content_id: "abc"})
      "/editor/posts/abc"

      iex> KilnCMS.Notifications.Link.editor_path("recipe", "r1", "b2")
      "/editor/content/recipe/r1?comment=b2"
  """
  @spec editor_path(subject()) :: String.t()
  def editor_path(%{content_type: content_type, content_id: content_id} = subject),
    do: editor_path(content_type, content_id, Map.get(subject, :block_id))

  @doc "The console path, from the three parts."
  @spec editor_path(String.t() | atom(), String.t(), String.t() | nil) :: String.t()
  def editor_path(content_type, content_id, block_id)

  def editor_path(content_type, content_id, nil), do: document_path(content_type, content_id)

  def editor_path(content_type, content_id, block_id) do
    document_path(content_type, content_id) <> "?" <> URI.encode_query(comment: block_id)
  end

  @doc "The absolute URL for the same link — what an email has to carry."
  @spec editor_url(subject()) :: String.t()
  def editor_url(%{content_type: content_type, content_id: content_id} = subject),
    do: editor_url(content_type, content_id, Map.get(subject, :block_id))

  @doc "The absolute URL, from the three parts."
  @spec editor_url(String.t() | atom(), String.t(), String.t() | nil) :: String.t()
  def editor_url(content_type, content_id, block_id \\ nil),
    do: KilnCMSWeb.Endpoint.url() <> editor_path(content_type, content_id, block_id)

  # Pages and posts have their own routes as well as the generic one; both
  # resolve to `ContentEditorLive`, so this is cosmetic — but it is the URL an
  # editor recognizes, and it was already what the workflow mail used.
  # Everything else, compiled or dynamic `:entry`, goes through `/content/`.
  #
  # `to_string/1` first: callers hand over both the string `content_type` a
  # notification stores and the `kind` atom the editor works in, and
  # `Phoenix.Param` has no atom implementation — an atom would raise here
  # rather than build a path.
  defp document_path(content_type, id), do: do_document_path(to_string(content_type), id)

  defp do_document_path("page", id), do: ~p"/editor/pages/#{id}"
  defp do_document_path("post", id), do: ~p"/editor/posts/#{id}"
  defp do_document_path(content_type, id), do: ~p"/editor/content/#{content_type}/#{id}"
end
