defmodule KilnCMS.CMS.MediaItem do
  @moduledoc """
  A media library item. Metadata only — the binary lives in object storage
  (local dev or S3/MinIO). The processing pipeline (`KilnCMS.ImageProcessor` +
  `Media.VariantWorker`) derives responsive variants and a focal-aware `card`
  crop centered on `focal_x`/`focal_y` (set by clicking the preview in the
  media library); `Media.Transform` provides in-admin rotate/flip edits — see
  docs/media-pipeline.md.

  Not every item is an image: #481 added documents and #494 added video, audio
  and WebVTT caption tracks, each with its own upload validator and (for A/V)
  its own background worker, `Media.AVWorker`. `KilnCMS.MediaKind.of/1` is the
  one place that decides which kind a row is, from its `content_type`.

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

    routes do
      base "/media-items"

      # Collection + single-record reads + full-text search for headless
      # consumers. Filtering/sorting/pagination are derived from the `:read`
      # action and public fields — documented in `docs/json-api.md`.
      index :read
      index :search, route: "/search"
      # `/:id` last so it can't shadow the static `/search` sub-path.
      get :read
    end
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
    # `all_tenants?: true` keeps `org_id` OUT of the GIN (a GIN can't lead with a
    # plain `org_id` column); the tenant filter rides the query's `WHERE org_id`
    # as a post-filter (mirrors the HNSW/trigram handling in `content.ex`).
    custom_indexes do
      index [
              "to_tsvector('english', coalesce(filename, '') || ' ' || coalesce(alt, '') || ' ' || coalesce(caption, ''))"
            ],
            name: "media_items_search_gin_index",
            using: "gin",
            all_tenants?: true
    end
  end

  # `:audience` is deliberately excluded from `@create_accept` (used only by
  # `:create`, below) — see that action's comment.
  @writable_fields [
    :filename,
    :content_type,
    :byte_size,
    :width,
    :height,
    :duration_seconds,
    :variants,
    # Written only by `Media.VariantWorker` alongside `variants` (#1000). Not
    # `public?`, so it is writable-by-the-pipeline without being part of the
    # headless surface.
    :variant_failures,
    :alt,
    :caption,
    :decorative,
    :storage_key,
    :url,
    :focal_x,
    :focal_y
  ]
  @create_accept @writable_fields

  actions do
    # Not atomic: the `BustMediaCache` after-action runs an in-BEAM side effect.
    destroy :destroy, primary?: true, require_atomic?: false

    default_accept @writable_fields ++ [:audience]

    # Primary read, paginated for the headless JSON:API media library (offset +
    # keyset, bounded page size). `required?: false` keeps `CMS.list_media_items`
    # returning a plain list for internal callers; only `page:`-passing callers
    # (the JSON:API layer) get a paginator.
    read :read do
      primary? true

      pagination offset?: true,
                 keyset?: true,
                 countable: true,
                 required?: false,
                 max_page_size: 100,
                 default_limit: 25
    end

    # No `:audience` (unlike `default_accept`, below, which every other
    # action uses): gating goes through `:update` only, where
    # `Changes.MigrateMediaStorage` can enforce "documents only" and
    # "private storage must be configured" against the transition it's
    # actually performing. A bare `create` with `audience: :member` would
    # skip both checks and the storage relocation entirely — the row would
    # claim to be gated while its blob sits wherever the caller's
    # `storage_key`/`url` point, public bucket included.
    create :create, primary?: true, accept: @create_accept

    # Not atomic: the `BustMediaCache` after-action runs an in-BEAM side effect.
    update :update do
      primary? true
      require_atomic? false
    end

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

    # System-only counter write (#481), same posture as
    # `KilnCMS.Analytics.ContentView`'s upserting counters — never in
    # `default_accept`, called only with `authorize?: false` from
    # `KilnCMSWeb.MediaDownloadController`.
    update :increment_downloads do
      accept []
      # Not atomic: `MigrateMediaStorage`'s `on: [:update]` hook applies to
      # every update-type action (mirrors `:restore` above, which sets the
      # same flag for the same reason) — and once an action isn't atomic,
      # `atomic_update/2`'s SQL expression is never sent, so the increment
      # has to be computed in Elixir instead (a `before_action` read of
      # `changeset.data`, same pattern `GenerateDkim` uses for a conditional
      # attribute write). This trades the single-statement atomicity of a
      # real `download_count + 1` for a rare lost-increment race under truly
      # concurrent downloads of the same document — the same tolerance
      # `KilnCMS.Analytics.ContentView`'s counters already accept.
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn cs ->
          Ash.Changeset.force_change_attribute(cs, :download_count, cs.data.download_count + 1)
        end)
      end
    end

    # Permanent hard delete (bypasses archival). The caller is responsible for
    # removing the storage blobs; admin-only via the destroy policy.
    destroy :purge do
      # Not atomic: the `BustMediaCache` after-action runs an in-BEAM side effect.
      require_atomic? false
    end

    # Full-text search over filename + alt + caption. World-readable like the
    # default read (media is referenced by published content).
    read :search do
      argument :query, :string, allow_nil?: false

      # Exposed on the public API — bound the response like Content's :search.
      pagination offset?: true,
                 keyset?: true,
                 countable: true,
                 required?: false,
                 max_page_size: 100,
                 default_limit: 25

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

        query
        |> Ash.Query.sort([
          {:search_rank, {%{query: q}, :desc}},
          {:inserted_at, :desc}
        ])
        |> KilnCMS.CMS.Content.cap_unbounded()
      end
    end
  end

  policies do
    # Read-scoped API keys can never write media, and no key may delete it —
    # before the admin bypass so a key on an admin account can't skip it
    # (mirrors the content policy; see Checks.ApiKeyWithoutWriteAccess).
    policy action_type([:create, :update]) do
      forbid_if KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess
      authorize_if always()
    end

    policy action_type(:destroy) do
      forbid_if AshAuthentication.Checks.UsingApiKey
      authorize_if always()
    end

    # Admins may do anything.
    bypass KilnCMS.CMS.Checks.OrgAdmin do
      authorize_if always()
    end

    # Media is world-readable **by default** — items are referenced by
    # published content and served to public/headless frontends. `audience`
    # (#481) narrows that for a gated document: editors always see the full
    # library (they need it to pick media for content, gated or not), a
    # `:public` item stays open to everyone, and anything else is checked
    # against the actor's held audiences the same way gated content is
    # (`Checks.MediaInAudience`).
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
      authorize_if expr(^ref(:audience) == :public)
      authorize_if KilnCMS.CMS.Checks.MediaInAudience
    end

    # Uploading and editing media metadata is reserved for editors (and admins
    # via the bypass above).
    policy action_type([:create, :update]) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
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

    # The download counter is written exclusively by
    # `KilnCMSWeb.MediaDownloadController` with `authorize?: false` — no actor
    # should ever be able to bump it directly (mirrors `ContentView`'s
    # system-only counter writes).
    policy action([:increment_downloads]) do
      forbid_if always()
    end
  end

  # A media write can invalidate any page that embeds this item's enriched media
  # (the delivery cache stores resolved srcset/alt/dimensions), so bust the
  # published-content cache on every create/update/destroy.
  changes do
    change KilnCMS.CMS.Changes.BustMediaCache, on: [:create, :update, :destroy]
    # Not atomic: relocates the blob between public/private storage — see the
    # module (#481).
    change KilnCMS.CMS.Changes.MigrateMediaStorage, on: [:update]
  end

  # Multi-tenancy (epic #336): media is per-site, partitioned by `org_id` (Ash
  # `:attribute` strategy — same axis as content). `global?: true` keeps a tenant
  # OPTIONAL: tenant-less reads/writes (editor, seeds, public delivery) keep
  # working and land in the default org (see the `org_id` default).
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set automatically from the tenant on a
    # scoped create, else defaults to the sole org; never accepted from input
    # (`writable?: false`, absent from `default_accept`) — the cross-site boundary.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    attribute :filename, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.identifier()]

    attribute :content_type, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.identifier()]

    attribute :byte_size, :integer, public?: true

    # Intrinsic pixel dimensions of the original. Written by
    # `Media.VariantWorker` for a raster image and by `Media.AVWorker` for a
    # video (#494); nil for audio, documents, and anything neither worker
    # could measure (no ffmpeg installed, an unreadable file).
    attribute :width, :integer, public?: true
    attribute :height, :integer, public?: true

    # Playback duration in seconds (#494) — video and audio only, and only
    # when ffprobe was available to measure it. Float rather than integer
    # because that is what ffprobe reports and rounding at write time would
    # lose the distinction between a 0.4s sting and an empty file.
    attribute :duration_seconds, :float, public?: true

    # Generated responsive variants, keyed by label:
    # %{"thumb" => %{"key" => ..., "url" => ..., "width" => ..., "height" => ...}}
    attribute :variants, :map, default: %{}, public?: true

    # Full-size alternates this source cannot be encoded to — `%{"webp" =>
    # "image too large"}` (#1000). Written by `KilnCMS.Media.VariantWorker` from
    # what `ImageProcessor.process/3` reports, and read by
    # `KilnCMS.Media.Regeneration.current?/1` so a missing-only run can tell
    # "not written yet" (re-enqueue it) from "will never be written" (leave it
    # alone). Without that distinction one of the two has to be wrong: either an
    # item that lost its top rung is never repaired, or an un-encodable panorama
    # is re-decoded on every run for ever.
    #
    # `public?: false` — it names an internal encoder limit, and `variants` is
    # public, so a headless consumer iterating one must not find the other's
    # failures mixed in. No length constraint: it is written by the pipeline
    # from a fixed set of format names, never from user input (#542).
    attribute :variant_failures, :map, default: %{}, public?: false

    attribute :alt, :string, public?: true, constraints: [max_length: KilnCMS.Limits.line()]

    attribute :caption, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.paragraph()]

    # Alt-text enforcement (#403). A decorative image — a divider, a texture, a
    # visual echo of adjacent text — correctly has NO alt text: a screen reader
    # should skip it, which HTML spells `alt=""`. That is indistinguishable from
    # "nobody got round to it" unless someone says so, and every form and import
    # in the world coerces a blank input to one or the other. So it's a recorded
    # decision rather than an inference from an empty string, and the publish
    # check (`Validations.MediaAltText`) treats it as satisfied.
    attribute :decorative, :boolean, allow_nil?: false, default: false, public?: true

    # The CDN/public url is the client-facing pointer; the raw storage key
    # is an internal implementation detail (#481: a gated item's key lives
    # in *private* storage, so exposing it would name something outside
    # every public interface for no reason a client needs). `public? false`
    # only affects JSON:API/GraphQL exposure — `storage_key` still flows
    # through `@writable_fields` for the internal writes that set it
    # (upload, `Media.Transform`, `Changes.MigrateMediaStorage`).
    attribute :storage_key, :string, public?: false
    attribute :url, :string, public?: true, constraints: [max_length: KilnCMS.Limits.url()]

    # Focal point (0.0–1.0) for smart cropping.
    attribute :focal_x, :float, default: 0.5, public?: true
    attribute :focal_y, :float, default: 0.5, public?: true

    # Consumer-facing access tier (#481, `KilnCMS.CMS.Audiences`) — the same
    # gate published content uses, applied to a document instead. `:public`
    # (the default) keeps every image and unrestricted document world-
    # readable, matching pre-#481 behavior exactly. Changing it moves the
    # underlying blob between public/private storage — see
    # `Changes.MigrateMediaStorage`; only a non-image item may hold a
    # non-public value (enforced there, not here, since the change needs to
    # know the transition to give a useful error).
    attribute :audience, :atom do
      constraints one_of: KilnCMS.CMS.Audiences.all()
      default :public
      allow_nil? false
      public? true
    end

    # Aggregate, count-only download total (#481) — privacy-first like every
    # other counter in this codebase (no per-viewer identity). Written only
    # by the `:increment_downloads` action from
    # `KilnCMSWeb.MediaDownloadController`; never accepted from outside.
    attribute :download_count, :integer do
      default 0
      allow_nil? false
      public? true
      writable? false
    end

    timestamps()
  end

  relationships do
    # The owning organization — the tenant axis is the `org_id` attribute above.
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end

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
