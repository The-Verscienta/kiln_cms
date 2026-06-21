defmodule KilnCMS.CMS.MediaItem do
  @moduledoc """
  A media library item. Metadata only — the binary lives in object storage
  (local dev or S3/MinIO). Variants/focal-point/processing pipeline land in v1.0.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource, AshGraphql.Resource, AshAdmin.Resource]

  graphql do
    type :media_item
  end

  json_api do
    type "media_item"
  end

  postgres do
    table "media_items"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :filename,
      :content_type,
      :byte_size,
      :alt,
      :caption,
      :storage_key,
      :url,
      :focal_x,
      :focal_y
    ]

    create :create, primary?: true
    update :update, primary?: true
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

    # Hard deletes are admin-only (allowed by the bypass; denied here for all
    # other roles).
    policy action_type(:destroy) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :filename, :string, allow_nil?: false, public?: true
    attribute :content_type, :string, public?: true
    attribute :byte_size, :integer, public?: true

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
end
