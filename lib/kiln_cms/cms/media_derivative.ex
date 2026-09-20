defmodule KilnCMS.CMS.MediaDerivative do
  @moduledoc """
  One cached on-the-fly transform of a `MediaItem` (`KilnCMS.Media.Derivatives`).

  The bytes live in blob storage under `storage_key`; this row exists so the
  cache can be **counted and cleaned**, which blob storage alone cannot do
  (S3 has no cheap "everything for this item", and the Local adapter keeps a
  flat directory):

    * **a per-item budget** — an allowlisted URL space is still large, and
      the row count is what turns "bounded" into a number;
    * **pruning** — a rotate or replace moves the item to a new original, and a
      focal move re-frames every focal crop. `source_key` and `focal` record
      what each derivative was cut from, so the ones the item can no longer
      produce are found and deleted instead of counting against the budget
      forever;
    * **purge** — permanently deleting the item deletes its derivatives' blobs
      (`MediaLive`'s purge path reads the keys first; the rows themselves go
      with the item through the foreign key).

  System-written and system-read only: no API surface, and no person — admin
  included — reads or writes a row directly.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "media_derivatives"
    repo KilnCMS.Repo

    references do
      # A purged item takes its rows with it. Its blobs are deleted by the purge
      # path, which reads the keys before the row disappears.
      reference :media_item, on_delete: :delete
    end

    # `for_item` is the only read: `(org_id, media_item_id)`, the shape the
    # tenant-scoped filter seeks.
    custom_indexes do
      index [:media_item_id], name: "media_derivatives_media_item_index"
    end
  end

  actions do
    defaults [:read, :destroy]

    read :for_item do
      argument :media_item_id, :uuid, allow_nil?: false
      filter expr(media_item_id == ^arg(:media_item_id))
    end

    # Upsert on the storage key: two requests that miss the cache for the same
    # derivative at once both render, both store the same bytes under the same
    # key, and must not leave two rows (and a double-counted budget) behind.
    create :record do
      upsert? true
      upsert_identity :unique_storage_key

      accept [
        :media_item_id,
        :storage_key,
        :source_key,
        :focal,
        :content_type,
        :byte_size,
        :width,
        :height,
        :private
      ]
    end
  end

  policies do
    # `KilnCMS.Media.Derivatives` is the only reader and writer this table has.
    # Who may SEE a transform is decided on the item, by the transform
    # controller's ordinary policy-checked `MediaItem` read.
    policy always() do
      authorize_if KilnCMS.Checks.SystemActor
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # Every field is `public? false`: this table has no API surface at all, and
    # each value is one `Media.Derivatives` wrote from its own plan — never
    # caller input, so none of them needs a length ceiling either. `accept`
    # takes private attributes (`MediaItem.storage_key` is the same shape).

    # `t-<32 hex>` — a digest of what was rendered (`ImageTransform.Plan`), so
    # the key alone says whether a derivative exists.
    attribute :storage_key, :string, allow_nil?: false, public?: false

    # The item's `storage_key` this was cut from — stale once it differs.
    attribute :source_key, :string, allow_nil?: false, public?: false

    # `"<x*1000>:<y*1000>"` of the focal point a focal crop was anchored on;
    # `nil` for anything that doesn't depend on it (a plain resize, a
    # centre-anchored crop), which a focal move therefore leaves valid.
    attribute :focal, :string, public?: false

    attribute :content_type, :string, allow_nil?: false, public?: false
    attribute :byte_size, :integer, allow_nil?: false, public?: false
    attribute :width, :integer, allow_nil?: false, public?: false
    attribute :height, :integer, allow_nil?: false, public?: false

    # Stored with `Storage.store_private/2` (an item not in the `:public`
    # audience), so deletion has to use the private half too.
    attribute :private, :boolean, allow_nil?: false, default: false, public?: false

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :media_item, KilnCMS.CMS.MediaItem do
      allow_nil? false
      attribute_writable? true
      public? false
    end

    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    identity :unique_storage_key, [:storage_key]
  end
end
