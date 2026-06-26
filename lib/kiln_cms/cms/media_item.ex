defmodule KilnCMS.CMS.MediaItem do
  @moduledoc """
  A media library item. Metadata only — the binary lives in object storage
  (local dev or S3/MinIO). Variants/focal-point/processing pipeline land in v1.0.

  Deletes are soft (AshArchival): `destroy` stamps `archived_at` and hides the
  row from reads, but keeps both the record and its storage blobs intact. That
  preserves referential integrity for published content still pointing at the
  item (`featured_image` FKs, block image URLs) until an admin restores it or
  permanently `:purge`s it.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [
      AshArchival.Resource,
      AshJsonApi.Resource,
      AshGraphql.Resource,
      AshAdmin.Resource
    ]

  graphql do
    type :media_item

    # No top-level queries (D7 — deliberate). Media is resolved only as a nested
    # `featuredImage` on content; the library itself isn't a public listing
    # endpoint (that's an admin concern via AshAdmin / the JSON:API).
  end

  json_api do
    type "media_item"
  end

  # Let `:trashed` see soft-deleted rows and `:purge` actually hard-delete.
  archive do
    exclude_read_actions([:trashed])
    exclude_destroy_actions([:purge])
  end

  # Content-focused AshAdmin overrides (issue #25). Group media with the other
  # content resources, show the columns a developer scanning the library cares
  # about (and hide the raw `variants` map / `storage_key` / focal point), and
  # label items by filename wherever they're referenced.
  admin do
    resource_group :content

    table_columns [:filename, :content_type, :byte_size, :width, :height, :alt, :inserted_at]

    format_fields inserted_at: {KilnCMS.CMS.Admin, :format_datetime, []},
                  updated_at: {KilnCMS.CMS.Admin, :format_datetime, []}

    relationship_display_fields [:filename]
    label_field :filename

    read_actions [:read, :search, :trashed]
    create_actions [:create]
    update_actions [:update, :restore]
    destroy_actions [:destroy, :purge]

    form do
      field :caption, type: :long_text
      field :alt, type: :short_text
    end
  end

  postgres do
    table "media_items"
    repo KilnCMS.Repo

    # GIN index backing the `:search` action — its expression matches the
    # `to_tsvector(...)` over filename/alt/caption in that action's filter.
    custom_indexes do
      index [
              "to_tsvector('english', coalesce(filename, '') || ' ' || coalesce(alt, '') || ' ' || coalesce(caption, ''))"
            ],
            name: "media_items_search_gin_index",
            using: "gin"
    end
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :filename,
      :content_type,
      :byte_size,
      :width,
      :height,
      :variants,
      :alt,
      :caption,
      :storage_key,
      :url,
      :focal_x,
      :focal_y
    ]

    create :create, primary?: true
    update :update, primary?: true

    # Soft-deleted ("trashed") media — the only read that bypasses AshArchival's
    # automatic `is_nil(archived_at)` filter.
    read :trashed do
      filter expr(not is_nil(^ref(:archived_at)))
    end

    # Bring a soft-deleted item back by clearing its archival timestamp.
    update :restore do
      accept []
      require_atomic? false
      change set_attribute(:archived_at, nil)
    end

    # Permanent hard delete (bypasses archival). The caller is responsible for
    # removing the storage blobs; admin-only via the destroy policy.
    destroy :purge do
    end

    # Full-text search over filename + alt + caption. World-readable like the
    # default read (media is referenced by published content).
    read :search do
      argument :query, :string, allow_nil?: false

      filter expr(
               fragment(
                 "to_tsvector('english', coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '')) @@ plainto_tsquery('english', ?)",
                 ^ref(:filename),
                 ^ref(:alt),
                 ^ref(:caption),
                 ^arg(:query)
               )
             )

      prepare fn query, _context ->
        q = Ash.Query.get_argument(query, :query)

        Ash.Query.sort(query, [
          {:search_rank, {%{query: q}, :desc}},
          {:inserted_at, :desc}
        ])
      end
    end
  end

  policies do
    # Admins may do anything.
    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    # Media is world-readable — items are referenced by published content and
    # served to public/headless frontends.
    policy action_type(:read) do
      authorize_if always()
    end

    # Uploading and editing media metadata is reserved for editors (and admins
    # via the bypass above).
    policy action_type([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :editor)
    end

    # Deletes are admin-only (allowed by the bypass; denied here for all other
    # roles). Covers both the soft `:destroy` and the permanent `:purge`.
    policy action_type(:destroy) do
      forbid_if always()
    end

    # Trash browsing and restore are admin-only too (mirrors delete).
    policy action([:trashed, :restore]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :filename, :string, allow_nil?: false, public?: true
    attribute :content_type, :string, public?: true
    attribute :byte_size, :integer, public?: true

    # Intrinsic pixel dimensions of the original (nil for non-raster uploads).
    attribute :width, :integer, public?: true
    attribute :height, :integer, public?: true

    # Generated responsive variants, keyed by label:
    # %{"thumb" => %{"key" => ..., "url" => ..., "width" => ..., "height" => ...}}
    attribute :variants, :map, default: %{}, public?: true

    attribute :alt, :string, public?: true
    attribute :caption, :string, public?: true

    # Storage pointer + public/CDN url.
    attribute :storage_key, :string, public?: true
    attribute :url, :string, public?: true

    # Focal point (0.0–1.0) for smart cropping.
    attribute :focal_x, :float, default: 0.5, public?: true
    attribute :focal_y, :float, default: 0.5, public?: true

    timestamps()
  end

  relationships do
    # One-to-many inverse of `belongs_to :featured_image` — the content items
    # using this media item as their lead image.
    has_many :featured_pages, KilnCMS.CMS.Page do
      destination_attribute :featured_image_id
      public? true
    end

    has_many :featured_posts, KilnCMS.CMS.Post do
      destination_attribute :featured_image_id
      public? true
    end
  end

  calculations do
    # Full-text relevance for the `:search` action — ts_rank over the same
    # filename/alt/caption tsvector the action filters on. Internal.
    calculate :search_rank,
              :float,
              expr(
                fragment(
                  "ts_rank(to_tsvector('english', coalesce(?, '') || ' ' || coalesce(?, '') || ' ' || coalesce(?, '')), plainto_tsquery('english', ?))",
                  ^ref(:filename),
                  ^ref(:alt),
                  ^ref(:caption),
                  ^arg(:query)
                )
              ) do
      argument :query, :string, allow_nil?: false
    end
  end
end
