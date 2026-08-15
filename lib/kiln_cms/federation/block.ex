defmodule KilnCMS.Federation.Block do
  @moduledoc """
  An actor or an instance this site refuses to federate with (#967).

  Phase 1 had no answer to "this follower is abusive" short of a database
  delete — which the next `Follow` undoes, because `Follower.follow` is an
  upsert. A block is the durable form of that decision: `KilnCMS.Federation.Inbox`
  refuses a `Follow` from a blocked actor, or from any actor on a blocked
  instance, before it writes anything; and blocking removes the matching
  followers already recorded, so deliveries stop with the block rather than
  at the next drop-after-failures sweep.

  Two kinds, matched the only way the data allows:

    * `:actor` — an exact actor URI (`https://mastodon.example/users/alice`).
    * `:instance` — a host (`mastodon.example`), matched against the host of
      the actor's URI, so a domain that mints a fresh actor per follow is one
      row here rather than one per actor.

  Admin-only writes, editor reads (the federation page shows the list beside
  the followers it explains). One row per `(org, kind, value)`; the value is
  normalized (trimmed, downcased host) on the way in so `Example.Social` and
  `example.social` cannot be two rows that match the same thing.
  """
  use Ash.Resource,
    domain: KilnCMS.Federation,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "federation_blocks"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :block do
      description "Refuse follows from an actor URI or an instance host."
      accept [:kind, :value, :reason]
      upsert? true
      upsert_identity :one_per_target
      upsert_fields [:reason]

      change fn changeset, _context ->
        Ash.Changeset.update_change(changeset, :value, &__MODULE__.normalize/1)
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
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

    attribute :kind, :atom do
      constraints one_of: [:actor, :instance]
      allow_nil? false
      public? true
    end

    # An actor URI or a host, per `kind`.
    attribute :value, :string do
      constraints max_length: KilnCMS.Limits.url()
      allow_nil? false
      public? true
    end

    attribute :reason, :string, public?: true, constraints: [max_length: KilnCMS.Limits.line()]

    timestamps()
  end

  relationships do
    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    identity :one_per_target, [:kind, :value]
  end

  @doc false
  # Hosts are case-insensitive and actor URIs are compared exactly (after a
  # trim), so a host is downcased and a URI is not.
  @spec normalize(term()) :: term()
  def normalize(value) when is_binary(value) do
    trimmed = String.trim(value)
    if String.contains?(trimmed, "://"), do: trimmed, else: String.downcase(trimmed)
  end

  def normalize(other), do: other
end
