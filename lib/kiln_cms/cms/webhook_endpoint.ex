defmodule KilnCMS.CMS.WebhookEndpoint do
  @moduledoc """
  A registered outbound webhook. When content is published, KilnCMS POSTs a
  signed payload to every active endpoint subscribed to that event (e.g.
  `"page.published"`). Admin-managed; the per-endpoint `secret` signs deliveries
  (HMAC-SHA256) so receivers can verify authenticity.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  @events ~w(page.published page.unpublished post.published post.unpublished)

  def events, do: @events

  postgres do
    table "webhook_endpoints"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:url, :events, :active]

    create :create do
      primary? true
      # A receiver-shared signing secret, generated once.
      change set_attribute(:secret, &__MODULE__.generate_secret/0)
      validate KilnCMS.CMS.Validations.WebhookUrl
    end

    update :update do
      primary? true
      require_atomic? false
      validate KilnCMS.CMS.Validations.WebhookUrl
    end
  end

  policies do
    # Webhook configuration is admin-only. The delivery pipeline reads endpoints
    # with `authorize?: false` as a system job.
    policy always() do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :url, :string, allow_nil?: false, public?: true

    # Subscribed event names; defaults to all known events (see `events/0`).
    attribute :events, {:array, :string} do
      default @events
      public? true
    end

    attribute :active, :boolean, default: true, public?: true

    attribute :secret, :string do
      allow_nil? false
      sensitive? true
      writable? false
    end

    timestamps()
  end

  @doc false
  def generate_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
