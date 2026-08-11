defmodule KilnCMS.CMS.FormSubmission do
  @moduledoc """
  One accepted submission of an admin-defined `Form`: the coerced `data` map
  (only defined field keys, JSON-native values), a moderation `status`, and
  when it arrived. Privacy-first like the rest of the analytics surface: **no
  IP, no user agent** — rate limiting uses the IP transiently and discards it.

  Written exclusively by `KilnCMS.Forms.submit/3` (validation, honeypot, and
  rate limiting happen there); admin-only to read, moderate, delete, or export.

  ## Moderation (#477)

  Every create is scored by `KilnCMS.CMS.Changes.ScoreFormSubmission` against
  the `Kiln.Forms.SpamCheck` registry: `spam_score` is the summed weight of
  every check that flagged it, and `status` starts `:spam` once that score
  clears `Kiln.Forms.SpamCheck.threshold/0`, `:new` otherwise. An admin can
  correct either direction with `:mark_spam`/`:mark_reviewed` — the latter
  covers both "reviewed a `:new` one" and "the scorer was wrong, this is
  fine", since both mean a human looked and it's not spam.

  `:spam` rows are excluded from the autoresponder/webhook dispatch (the
  private `record/3` inside `KilnCMS.Forms.submit/3`) and pruned after
  `Application.compile_env(:kiln_cms, [:forms, :spam_retention_days], 30)`
  days by a nightly `AshOban` trigger — moderation history for legitimate
  submissions (`:new`/`:reviewed`) is kept indefinitely, same as before #477.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban, AshAdmin.Resource]

  # Days a `:spam` row is kept before the nightly prune. Non-spam rows are
  # never pruned by this trigger.
  @spam_retention_days Application.compile_env(:kiln_cms, [:forms, :spam_retention_days], 30)

  @doc "Days a spam-flagged submission is retained before the nightly prune."
  @spec spam_retention_days() :: pos_integer()
  def spam_retention_days, do: @spam_retention_days

  admin do
    resource_group :content
    table_columns [:form_id, :status, :spam_score, :inserted_at]
  end

  postgres do
    table "form_submissions"
    repo KilnCMS.Repo

    references do
      reference :form, on_delete: :delete
    end
  end

  oban do
    use_tenant_from_record? true

    triggers do
      # Nightly spam-row prune — mirrors WebhookDelivery's ledger prune.
      # Legitimate submissions (:new/:reviewed) are never touched by this.
      trigger :prune_spam do
        action :destroy
        queue :default
        scheduler_cron "35 3 * * *"
        list_tenants KilnCMS.Accounts.ListOrgIds

        where expr(status == :spam and inserted_at <= ago(^@spam_retention_days, :day))

        worker_read_action :read
        worker_module_name KilnCMS.CMS.FormSubmission.Workers.PruneSpam
        scheduler_module_name KilnCMS.CMS.FormSubmission.Schedulers.PruneSpam
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:form_id, :data, :locale]

      # Not stored — only the scorer's `Kiln.Forms.SpamCheck.Checks.FillTime`
      # reads it, via the change below. `KilnCMS.Forms.submit/3` computes it
      # from a signed render-time token; a headless/JSON caller with no
      # rendered page to time simply omits it.
      argument :fill_time_ms, :integer

      change KilnCMS.CMS.Changes.ScoreFormSubmission
    end

    # Confirmed spam: the scorer missed it, or an admin caught something new.
    update :mark_spam do
      accept []
      change set_attribute(:status, :spam)
    end

    # A human looked and it's not spam — whether it started `:new` or the
    # scorer flagged it wrongly. Either way the mail/webhook gate
    # (`KilnCMS.Forms.record/3`) only ever runs once, at submit time, so
    # correcting a false positive here does not retroactively fire them.
    update :mark_reviewed do
      accept []
      change set_attribute(:status, :reviewed)
    end

    # Submissions of one form, newest first, optionally filtered by
    # moderation status (the form-builder Entries tab).
    read :recent_for_form do
      argument :form_id, :uuid, allow_nil?: false
      argument :status, :atom, constraints: [one_of: [:new, :reviewed, :spam]]

      filter expr(
               form_id == ^arg(:form_id) and
                 (is_nil(^arg(:status)) or status == ^arg(:status))
             )

      prepare build(sort: [inserted_at: :desc], limit: 100)
    end

    # The CSV export's read: same filter as above, no row cap.
    read :for_export do
      argument :form_id, :uuid, allow_nil?: false
      argument :status, :atom, constraints: [one_of: [:new, :reviewed, :spam]]

      filter expr(
               form_id == ^arg(:form_id) and
                 (is_nil(^arg(:status)) or status == ^arg(:status))
             )

      prepare build(sort: [inserted_at: :desc])
    end
  end

  policies do
    # The nightly prune trigger runs as a system job.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Submission contents are visitor-provided data — admin eyes only. The
    # accept pipeline writes with authorize?: false after validating.
    policy always() do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end

  # Multi-tenancy (epic #336): a submission belongs to the same site as its form.
  # `global?: true` keeps the tenant optional; the delivery-path create
  # (`KilnCMS.Forms.record`, `authorize?: false`) MUST carry the form's tenant so
  # the submission lands in the right site (see `KilnCMS.Forms`).
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant (the form's org) on
    # the delivery-path create, else the default org.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # Coerced field values, keyed by FormField name.
    attribute :data, :map, allow_nil?: false, default: %{}, public?: true

    # The locale of the page the form was submitted from, when known.
    attribute :locale, :string,
      public?: true,
      constraints: [max_length: KilnCMS.Limits.identifier()]

    # Moderation status (#477). Not writable directly — only
    # `Changes.ScoreFormSubmission` (on create) and the `:mark_spam`/
    # `:mark_reviewed` actions ever set it.
    attribute :status, :atom do
      constraints one_of: [:new, :reviewed, :spam]
      default :new
      allow_nil? false
      writable? false
      public? true
    end

    # The summed weight of every `Kiln.Forms.SpamCheck` that flagged this
    # submission — 0 for a clean one. Kept even when `status` is later
    # corrected by hand, so "the scorer thought this was a 65" stays visible
    # after an admin marks it reviewed.
    attribute :spam_score, :integer do
      default 0
      allow_nil? false
      writable? false
      public? true
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

    belongs_to :form, KilnCMS.CMS.Form do
      allow_nil? false
      public? true
    end
  end
end
