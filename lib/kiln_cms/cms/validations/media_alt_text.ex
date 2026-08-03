defmodule KilnCMS.CMS.Validations.MediaAltText do
  @moduledoc """
  Blocks publishing a document that shows an image with no alt text (#403).

  `alt` has always been optional, which means it is missing on exactly the
  images nobody thought about. A screen-reader user meets those as "image", or
  as a filename read aloud one character at a time.

  ## It checks the alt that actually renders

  The `alt` attribute in the delivered HTML comes from the **block's** own `alt`
  field — the image block's own renderer emits `esc(block.alt || "")`, and
  `KilnCMSWeb.BlockComponents` renders `@block[:alt] || ""`. The library item's
  `MediaItem.alt` is the editor's default when inserting an image; it is not
  what ships.

  So this walks the block tree, not the media library. Checking `MediaItem.alt`
  instead would get it wrong in both directions: refusing a page whose image
  block carries a perfectly good description because the library row is blank,
  and publishing a page that renders `alt=""` because some library row it points
  at happens to be filled in.

  A block with no resolvable media item is checked the same way — an image
  pasted in by URL renders an `alt` attribute like any other.

  ## Decorative is an answer, not an omission

  A divider, a texture, an image that only repeats the sentence beside it —
  those correctly have *no* alt text, which HTML spells `alt=""`.
  `MediaItem.decorative` records that as a decision, so a blank block alt is
  accepted when the block points at a media item marked decorative. Without
  somewhere to say it, "deliberately silent" is indistinguishable from "nobody
  got round to it", which is the whole difficulty with linting alt text.

  ## Enforced at publish, config-gated, off by default

      config :kiln_cms, :media, require_alt_text: true

  Publish rather than upload: what matters is whether the *published page* is
  readable, and a required field on upload blocks a bulk import, has nothing to
  say about decorative images, and makes every item already in the library
  retroactively invalid. Off, this is a no-op, so an existing library keeps
  publishing. On, the error names every offender at once rather than making an
  editor rediscover the next one on each retry.
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias KilnCMS.Blocks.Columns
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.CMS.TypedBlocks

  @impl true
  def validate(changeset, _opts, _context) do
    if required?() do
      check(changeset)
    else
      :ok
    end
  end

  defp check(changeset) do
    case offenders(changeset) do
      [] ->
        :ok

      labels ->
        {:error,
         field: :state,
         message:
           "cannot publish: #{Enum.join(labels, ", ")} " <>
             "#{if length(labels) == 1, do: "has", else: "have"} no alt text. " <>
             "Add a description, or mark the image decorative."}
    end
  end

  defp offenders(changeset) do
    # The blocks as they will be after this change — a publish that also edits
    # the body must be judged on what it is about to show.
    blocks =
      changeset
      |> Ash.Changeset.get_attribute(:blocks)
      |> TypedBlocks.to_typed()
      |> flatten()

    case Enum.filter(blocks, &image_without_alt?/1) do
      [] ->
        []

      candidates ->
        decorative = decorative_ids(candidates, changeset.data.org_id)

        candidates
        |> Enum.reject(&(media_id(&1) in decorative))
        |> Enum.map(&label/1)
        |> Enum.uniq()
        |> Enum.sort()
    end
  end

  # A block renders an `alt` attribute if it has an `alt` field at all; that is
  # the same test the renderers make, rather than a hardcoded list of block
  # types that a plugin block would fall off.
  defp image_without_alt?(block) do
    Map.has_key?(block, :alt) and blank?(Map.get(block, :alt))
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp flatten(blocks) do
    Enum.flat_map(List.wrap(blocks), fn
      %Columns{} = block -> block |> Columns.child_blocks_flat() |> flatten()
      block -> [block]
    end)
  end

  # One query for every candidate, not one per block.
  defp decorative_ids(candidates, org_id) do
    candidates
    |> Enum.map(&media_id/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> case do
      [] ->
        []

      ids ->
        MediaItem
        |> Ash.Query.filter(id in ^ids and decorative == true)
        |> Ash.Query.select([:id])
        |> Ash.read!(authorize?: false, tenant: org_id)
        |> Enum.map(& &1.id)
    end
  end

  defp media_id(block) do
    case Map.get(block, :media_id) do
      id when is_binary(id) -> id
      _other -> nil
    end
  end

  # Named by whatever the editor will recognise: the image's URL is on the block
  # and needs no lookup, and it is what they see in the editor.
  defp label(block) do
    case Map.get(block, :url) do
      url when is_binary(url) and url != "" -> url
      _other -> "an image block"
    end
  end

  defp required? do
    :kiln_cms |> Application.get_env(:media, []) |> Keyword.get(:require_alt_text, false)
  end
end
