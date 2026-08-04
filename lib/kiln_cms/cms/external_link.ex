defmodule KilnCMS.CMS.ExternalLink do
  @moduledoc """
  One outbound URL, in one document, and what happened the last time it was
  checked (#474).

  `Kiln.Advisory.Finding` is in-memory by design — the editor recomputes it on a
  keystroke and nothing is stored. That works because the internal checker runs
  *on the document being edited*. The external checker is a scheduled sweep over
  everything, answering a question nobody has an editor open for ("what on this
  whole site is broken?"), so its findings have to survive the run that produced
  them.

  ## A row is an occurrence, not a URL

  The grain is `{document, url}`, so the same URL cited by forty documents is
  forty rows. That is what the report needs — "this link is dead, here is
  everywhere it appears" — and it is what makes cleanup local: re-sweeping one
  document rewrites only that document's rows.

  The *check* is still per URL. `KilnCMS.Links.CheckWorker` requests each
  distinct `url_digest` once and writes the verdict to every row that shares it,
  so forty citations cost one request, not forty. Rows added between checks sit
  at `:pending` until the next sweep reaches them.

  `url_digest` exists because Postgres will not index 2KB of URL comfortably and
  because equality on a 64-character hex string is cheaper than on a long
  string. It is derived on write (`Changes.DigestUrl`), never accepted.

  ## Reconciliation, and why `last_seen_at` is a column

  A document that is edited, unpublished or deleted must not leave its old links
  in the report. The sweep stamps `last_seen_at` on every row it re-observes and
  then deletes this org's rows older than the run — which covers "the author
  removed that link", "the document was unpublished" and "the document is gone"
  with one rule rather than three hooks that each have to remember.

  ## What is stored is only ever what a reader would hit

  Only `:broken` rows are shown. `:transient` and `:undetermined` are recorded
  so the next run can tell a second failure from a first, and so an operator can
  see that a check ran at all — see `KilnCMS.Links.External` for what those
  outcomes mean and why almost nothing qualifies as broken.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "external_links"
    repo KilnCMS.Repo

    custom_indexes do
      # The check fans one verdict out to every occurrence of a URL, and the
      # sweep asks which digests are due. Both are digest-keyed. (Ash prepends
      # the tenant attribute, so this is really `(org_id, url_digest)`.)
      index [:url_digest]
      # The report reads one outcome out of a table that is mostly `:ok`.
      index [:outcome]
    end
  end

  actions do
    defaults [:read, :destroy]

    default_accept []

    # Record that `url` appears in a document, without disturbing what is known
    # about the URL itself.
    #
    # `upsert_fields` is the whole point: a re-sweep refreshes where the link is
    # (title, block, `last_seen_at`) and deliberately leaves `outcome`,
    # `failure_count` and `first_failed_at` alone. Resetting those on every
    # sweep would restart the retry-before-flagging count nightly, and a link
    # that fails every night would never reach the threshold that flags it.
    create :observe do
      primary? true
      upsert? true
      upsert_identity :unique_occurrence

      accept [:url, :document_type, :document_id, :document_title, :block_index]

      upsert_fields [:document_title, :block_index, :host, :url_digest, :last_seen_at]

      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
    end

    # Write one check's verdict. Applied in bulk to every row sharing a digest.
    update :record_check do
      require_atomic? false

      accept [:outcome, :status_code, :reason, :failure_count]

      change set_attribute(:last_checked_at, &DateTime.utc_now/0)
      change KilnCMS.CMS.Changes.StampFirstFailure
    end
  end

  policies do
    # Editors read the report; it is editorial work, not administration.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Nothing writes these by hand. The sweep and the check worker run
    # system-side (`authorize?: false`); the admin clause exists so that a
    # "dismiss this row" affordance added later has a policy to land on rather
    # than a resource that forbids everything.
    policy action_type([:create, :update, :destroy]) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  changes do
    change KilnCMS.CMS.Changes.DigestUrl, on: [:create]
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

    # Bounded well under Postgres' btree limit even before the digest takes over
    # indexing duty. Longer than this is not a link an author typed.
    attribute :url, :string do
      allow_nil? false
      public? true
      constraints max_length: 2048
    end

    # SHA-256 (hex) of `url`, derived by `Changes.DigestUrl`. Not writable: a
    # caller that could set it could make two different URLs share a verdict.
    attribute :url_digest, :string do
      allow_nil? false
      writable? false
      public? true
      constraints max_length: 64
    end

    # Derived alongside the digest, and stored rather than parsed on read so the
    # report can group by domain without re-parsing every row.
    attribute :host, :string do
      writable? false
      public? true
      constraints max_length: 253
    end

    # The document this occurrence is in. A type string + id rather than a
    # relationship, because content lives in several tables (`Page`, `Post`, the
    # shared `Entry` tier) and a foreign key can only point at one of them.
    attribute :document_type, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :document_id, :uuid do
      allow_nil? false
      public? true
    end

    # Denormalized for the report, refreshed on every sweep. A join is not
    # available (see above), and a report that has to load each document to name
    # it is a report that loads every document.
    attribute :document_title, :string do
      public? true
      constraints max_length: 512
    end

    # Which top-level block holds the link, so "somewhere in this 60-block page"
    # becomes "block 12". `nil` when the URL came from somewhere other than the
    # block tree.
    attribute :block_index, :integer, public?: true

    # See `KilnCMS.Links.External` for what each of these means. `:pending` is
    # the state of a newly observed occurrence that no check has reached yet —
    # distinct from `:undetermined`, which means a check ran and declined to
    # judge.
    attribute :outcome, :atom do
      default :pending
      allow_nil? false
      public? true
      constraints one_of: [:pending, :ok, :broken, :transient, :undetermined]
    end

    attribute :status_code, :integer, public?: true

    attribute :reason, :string do
      public? true
      constraints max_length: 512
    end

    # Consecutive non-`:ok` checks. The retry-before-flagging counter: a 5xx or
    # a failed resolution has to repeat before it is reported, because the web
    # has bad minutes and an author should not hear about them.
    attribute :failure_count, :integer do
      default 0
      allow_nil? false
      public? true
    end

    # When the current run of failures started, so the report can say "failing
    # since Tuesday" rather than only "failing".
    attribute :first_failed_at, :utc_datetime_usec, public?: true
    attribute :last_checked_at, :utc_datetime_usec, public?: true

    # When the sweep last saw this URL in this document. Older than the current
    # run means the link is gone; see the moduledoc.
    attribute :last_seen_at, :utc_datetime_usec, public?: true

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
    identity :unique_occurrence, [:document_type, :document_id, :url_digest]
  end
end
