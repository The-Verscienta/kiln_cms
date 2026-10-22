defmodule KilnCMS.Media.Snapshot do
  @moduledoc """
  The one JSON shape a media item is delivered in: a `:media` custom field's
  stored value (single, or each item of a gallery `multiple` field) and the
  `"media"` key the fired `:json` artifact adds to `image` blocks and to each
  `gallery` image. One shape, so an app needs one decoder.

      %{
        "id" => "…", "url" => "https://…/orig.jpg", "alt" => "…",
        "width" => 1600, "height" => 900, "mime_type" => "image/jpeg",
        "focal" => %{"x" => 0.5, "y" => 0.3},
        "variants" => [
          %{"label" => "thumb", "width" => 400, "height" => 225,
            "format" => "image/jpeg", "url" => "…", "bytes" => 18_204,
            "cropped" => false},
          %{"label" => "card.webp", "width" => 800, "height" => 450,
            "format" => "image/webp", "url" => "…", "bytes" => 30_112,
            "cropped" => true},
          …
        ]
      }

  `id`, `url` and `alt` are what the snapshot always carried; everything else
  was added for native apps (`docs/plans/2026-10-22-mobile-delivery-gaps.md`
  §4) and is additive.

    * `width`/`height` are the original's intrinsic size, `nil` until
      `KilnCMS.Media.VariantWorker` has measured it.
    * `mime_type` is the original's content type.
    * `focal` is the focal point as fractions of the width and height, for an
      image; `nil` for a video, audio file or document, where it means nothing.
    * `variants` lists every derived rendition, smallest first. `format` is
      its MIME type (a variant exists in the source format and in each
      configured alternate, #473). `bytes` is `nil` for a variant written
      before sizes were recorded, or rendered by an image backend.
    * `cropped: true` marks a rendition that is *not* the same picture at
      another size — the focal-aware crops and a video's poster frame
      (`KilnCMS.Media.Presentation.excluded_labels/0`). An app choosing by
      width must skip them, for the reason a `srcset` must (see
      `Presentation`); one wanting a fixed-ratio card picks them by label.

  ## When it is taken, and how it stays current

  Variants are derived asynchronously, after the upload. A document saved
  before that finishes stores `"variants" => []` and `nil` dimensions —
  the snapshot records what exists at the time, it does not wait. Three things
  bring it up to date:

    * **firing** re-reads every snapshotted item
      (`KilnCMS.Firing.CustomFields`), so a fired artifact — what
      `GET /api/content/:type/:slug` and `/api/sync` serve — carries the
      item's current shape whenever the document fires;
    * **a media change re-fires its referrers**: a write that changes what
      this shape is built from (`rendered_fields/0`) — the variant worker
      finishing, a moved focal point, new alt text — re-fires the published
      documents that point at the item
      (`KilnCMS.CMS.Changes.RefireMediaReferrers`);
    * **the stored value** (what JSON:API and GraphQL read straight off the
      row) is refreshed by the document's next save, or for every record at
      once by `mix kiln.media.resnapshot`.

  Firing does not rewrite the stored value: that is a content write, with a
  version and an `updated` webhook, and a variant run is not an edit.
  """

  alias KilnCMS.HTMLSanitizer
  alias KilnCMS.Media.Presentation
  alias KilnCMS.MediaKind

  @doc """
  The `MediaItem` attributes the shape is built from. A write changing none of
  them leaves every snapshot of the item as it is.
  """
  @spec rendered_fields() :: [atom()]
  def rendered_fields,
    do: [:url, :alt, :width, :height, :content_type, :variants, :focal_x, :focal_y]

  @doc "The delivered shape of `item` (a `KilnCMS.CMS.MediaItem`)."
  @spec of(map()) :: map()
  def of(item) do
    %{
      "id" => item.id,
      "url" => item.url,
      "alt" => item.alt,
      "width" => item.width,
      "height" => item.height,
      "mime_type" => item.content_type,
      "focal" => focal(item),
      "variants" => variants(item)
    }
  end

  defp focal(%{focal_x: x, focal_y: y} = item) when is_number(x) and is_number(y) do
    if MediaKind.of(item.content_type) == :image, do: %{"x" => x, "y" => y}
  end

  defp focal(_item), do: nil

  # Every url goes through `safe_image_src/1`, as `Presentation`'s do: the
  # entries are generated internally, but an operator-set storage prefix is
  # part of every one, and an app may hand the url straight to a web view.
  defp variants(item) do
    excluded = Presentation.excluded_labels()

    for {label, %{"url" => url} = variant} <- item.variants || %{},
        safe = HTMLSanitizer.safe_image_src(url),
        is_binary(safe) do
      %{
        "label" => label,
        "width" => variant["width"],
        "height" => variant["height"],
        "format" => variant["content_type"] || item.content_type,
        "url" => safe,
        "bytes" => variant["bytes"],
        "cropped" => KilnCMS.ImageProcessor.base_label(label) in excluded
      }
    end
    |> Enum.sort_by(&{&1["cropped"], &1["width"] || 0, &1["label"]})
  end

  @doc """
  Every media id a stored custom-field value names: a single snapshot, a
  gallery list of them, or nothing.
  """
  @spec ids(term()) :: [String.t()]
  def ids(%{"id" => id, "url" => _}) when is_binary(id), do: [id]
  def ids(list) when is_list(list), do: Enum.flat_map(list, &ids/1)
  def ids(_value), do: []

  @doc """
  A stored custom-field value with each snapshot rebuilt from `items` (id →
  `MediaItem`). A snapshot whose item is not in `items` — deleted since, or
  in another site — keeps its stored shape, as delivery always has.
  """
  @spec refresh(term(), %{String.t() => map()}) :: term()
  def refresh(%{"id" => id, "url" => _} = snapshot, items) do
    case Map.fetch(items, id) do
      {:ok, item} -> of(item)
      :error -> snapshot
    end
  end

  def refresh(list, items) when is_list(list), do: Enum.map(list, &refresh(&1, items))
  def refresh(value, _items), do: value

  @doc """
  Read `ids` for delivery, as `{id => MediaItem}`.

  `authorize?: false` under the document's own tenant, as
  `KilnCMSWeb.ContentController` reads block media: the ids come from a
  document already resolved for delivery, and the tenant keeps the read to its
  own site (#336). Non-uuids are dropped first — `media_id` on a block is free
  text, and a junk value would make the read raise.
  """
  @spec load(Ash.UUID.t() | nil, [term()]) :: %{String.t() => map()}
  def load(org_id, ids) do
    case ids |> Enum.filter(&uuid?/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        KilnCMS.CMS.list_media_items!(
          # authorize?: false — delivery read of ids from a resolved document, tenant-scoped (above)
          authorize?: false,
          tenant: org_id,
          query: [filter: [id: [in: ids]]]
        )
        |> Map.new(&{&1.id, &1})
    end
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  @doc """
  The JSON Schema of the shape, for `KilnCMS.SchemaExport`. Open
  (`additionalProperties`), so a later key is not a breaking change for a
  validating consumer; only the keys every snapshot ever carried are required —
  a value stored before the rest existed lacks them until it is re-saved.
  """
  @spec json_schema() :: map()
  def json_schema do
    nullable_int = %{"type" => ["integer", "null"]}

    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "format" => "uuid"},
        "url" => %{"type" => ["string", "null"]},
        "alt" => %{"type" => ["string", "null"]},
        "width" => nullable_int,
        "height" => nullable_int,
        "mime_type" => %{"type" => ["string", "null"]},
        "focal" => %{
          "type" => ["object", "null"],
          "properties" => %{"x" => %{"type" => "number"}, "y" => %{"type" => "number"}},
          "required" => ["x", "y"]
        },
        "variants" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "label" => %{"type" => "string"},
              "width" => nullable_int,
              "height" => nullable_int,
              "format" => %{"type" => ["string", "null"]},
              "url" => %{"type" => "string"},
              "bytes" => nullable_int,
              "cropped" => %{"type" => "boolean"}
            },
            "required" => ["label", "url", "cropped"],
            "additionalProperties" => true
          }
        }
      },
      "required" => ["id", "url"],
      "additionalProperties" => true
    }
  end
end
