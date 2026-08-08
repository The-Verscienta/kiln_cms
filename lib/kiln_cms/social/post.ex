defmodule KilnCMS.Social.Post do
  @moduledoc """
  The announcement ledger (#497): one row per {rule, account, document,
  publish}, recording what Kiln tried to post and what came back.

  ## The row is the claim, not the receipt

  It is written **before** the provider is called, in the `:claimed` state, and
  the unique identity below is what makes "post once" true. Two concurrent
  workers — a re-delivered Oban job, a re-fire wave, two nodes — both try to
  insert; Postgres lets exactly one through and the loser sees a conflict and
  stops. Checking a table first and then posting would let both pass the check.

  That ordering is deliberate even though it means a crash between the insert
  and the request leaves a `:claimed` row for a post that never happened. That
  failure is *visible and recoverable* — the row is right there in the ledger
  with a timestamp, and an operator can re-trigger it. The opposite ordering
  fails by posting twice to a public timeline, which is neither.

  ## States

    * `:claimed` — the row won the race; the request has not returned.
    * `:posted` — the provider confirmed, `remote_id` is set.
    * `:failed` — the provider definitely did **not** post (a 4xx, bad
      credentials, a refused body). Safe to re-trigger.
    * `:unknown` — the request may or may not have landed: a timeout after the
      bytes went out, a 5xx, a reset. **Never retried automatically.** A
      duplicate announcement is worse than a missing one, because the missing
      one is invisible and the duplicate is on the operator's public timeline in
      front of their audience. A human decides.
    * `:skipped` — deliberately not posted (gated, locked, or non-default
      locale). Recorded rather than dropped so "why didn't this post?" has an
      answer in the same place as everything else.

  Re-announcing on purpose means deleting the ledger row: the claim IS the
  record of "this has been announced", so there is nothing else to clear. That
  is deliberately a manual, admin-only act rather than a button, because every
  automatic path to it is a path to a duplicate.

  Terminal by design: there is no retry state machine. Oban's `max_attempts` is
  1 on the announce worker for the same reason.
  """
  use Ash.Resource,
    domain: KilnCMS.Social,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  @states [:claimed, :posted, :failed, :unknown, :skipped]

  @doc "Ledger states."
  def states, do: @states

  admin do
    resource_group :system
    table_columns [:provider, :content_type, :state, :remote_url, :inserted_at]
  end

  postgres do
    table "social_posts"
    repo KilnCMS.Repo

    references do
      reference :account, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :account_id,
      :provider,
      :content_type,
      :content_id,
      :content_published_at,
      :automation_rule_id,
      :text,
      :url
    ]

    # The claim. `upsert?` is deliberately NOT set: a conflict must surface as an
    # error the caller stops on, not quietly become an update that lets a second
    # worker carry on and post.
    create :claim do
      primary? true
    end

    update :succeed do
      accept [:remote_id, :remote_url]
      require_atomic? false
      change set_attribute(:state, :posted)
      change set_attribute(:posted_at, &DateTime.utc_now/0)
    end

    update :fail do
      accept [:error]
      require_atomic? false
      change set_attribute(:state, :failed)
    end

    update :unresolved do
      accept [:error]
      require_atomic? false
      change set_attribute(:state, :unknown)
    end

    update :skip do
      accept [:error]
      require_atomic? false
      change set_attribute(:state, :skipped)
    end

    read :recent do
      prepare build(sort: [inserted_at: :desc], limit: 50, load: [:account])
    end
  end

  policies do
    policy always() do
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

    attribute :account_id, :uuid, allow_nil?: false, public?: true

    # Denormalized from the account so the ledger still reads after an account
    # is deleted... except the FK cascades, so this is really for the admin
    # table's benefit — one less join to show what a row was.
    attribute :provider, :atom do
      allow_nil? false
      constraints one_of: KilnCMS.Social.Account.providers()
      public? true
    end

    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true

    # The publish instant this announcement is for. Part of the dedupe key, so
    # a genuinely new publish announces again while a re-fire of the same one
    # does not — the same shape `KilnCMS.Newsletter.Send` uses.
    #
    # `allow_nil? false` because it is IN that key: a nullable column in a
    # unique index is not a constraint at all (NULLs compare distinct). Only
    # published documents are announced, so they always have one.
    attribute :content_published_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :automation_rule_id, :uuid, public?: true

    attribute :state, :atom do
      allow_nil? false
      default :claimed
      constraints one_of: @states
      public? true
    end

    # What was sent, kept verbatim: when an operator asks why a post reads the
    # way it does, the answer should not require re-deriving it from a template
    # and a since-edited document.
    attribute :text, :string, public?: true, constraints: [max_length: KilnCMS.Limits.paragraph()]
    attribute :url, :string, public?: true, constraints: [max_length: KilnCMS.Limits.url()]

    attribute :remote_id, :string, public?: true
    attribute :remote_url, :string, public?: true, constraints: [max_length: KilnCMS.Limits.url()]
    attribute :error, :string, public?: true
    attribute :posted_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :account, KilnCMS.Social.Account do
      source_attribute :account_id
      define_attribute? false
      attribute_writable? false
      public? true
    end

    belongs_to :organization, KilnCMS.Accounts.Organization do
      source_attribute :org_id
      define_attribute? false
      attribute_writable? false
      public? false
    end
  end

  identities do
    # THE at-most-once guarantee — and every column in it is NOT NULL, which is
    # the whole point.
    #
    # `automation_rule_id` was in this key at first and had to come out:
    # Postgres treats NULLs as **distinct**, so a key containing a nullable
    # column silently stops deduplicating the moment that column is null. Every
    # announce that did not come from a rule would have re-posted, and the
    # index would still have looked like it was doing its job.
    #
    # Leaving the rule out is also the better guarantee. "Once per document per
    # account per publish" is what an operator actually wants; keying on the
    # rule would let two rules pointed at the same account both announce the
    # same document, which is the duplicate this exists to prevent.
    identity :announce_once, [:account_id, :content_id, :content_published_at]
  end

  @type t :: %__MODULE__{}
end
