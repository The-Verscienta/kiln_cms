defmodule KilnCMS.CMS.Consent do
  @moduledoc """
  An **editorial / authorization consent** record linked to a content item
  (compliance cluster, #356) — proof that a piece of content is *cleared to
  publish*: a medical-reviewer sign-off, a patient/source release, source
  licensing, and so on.

  This is *cleared-to-publish* consent, **not** GDPR data-subject/cookie consent.
  A record stores a **reference** to the underlying authorization (a ticket id,
  URL, or document ref) and who granted it — deliberately **never the sensitive
  consent document itself**, so PHI-adjacent material isn't pulled into the CMS.

  Consents surface in the governance dashboard (#352) and can gate publishing
  (see `KilnCMS.CMS.Validations.RequiredConsent`, config-gated). Recording and
  reading are editor/admin; deletion is admin-only; the publish gate reads as the
  system.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAdmin.Resource]

  # Kinds of editorial consent; override per deployment.
  @kinds Application.compile_env(:kiln_cms, [:consent, :kinds], [
           :reviewer_signoff,
           :source_release,
           :licensing,
           :other
         ])

  @doc "The configured consent kinds."
  def kinds, do: @kinds

  admin do
    resource_group :system
    table_columns [:content_type, :kind, :grantor, :granted_at, :inserted_at]
  end

  postgres do
    table "content_consents"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      primary? true
      accept [:content_type, :content_id, :kind, :reference, :grantor, :note, :granted_at]

      # Stamp who recorded it, from the acting user.
      change fn changeset, context ->
        case context.actor do
          %{id: id} -> Ash.Changeset.force_change_attribute(changeset, :recorded_by_id, id)
          _ -> changeset
        end
      end
    end

    read :for_content do
      argument :content_type, :string, allow_nil?: false
      argument :content_id, :uuid, allow_nil?: false

      filter expr(content_type == ^arg(:content_type) and content_id == ^arg(:content_id))
      prepare build(sort: [granted_at: :desc])
    end
  end

  policies do
    # Recording and reading consent is an editorial action (editors + admins).
    policy action_type([:create, :read]) do
      authorize_if actor_attribute_equals(:role, :editor)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Deletion is admin-only (compliance records shouldn't be casually removed).
    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  # Multi-tenancy (epic #336): a consent belongs to the same site as the content
  # it clears. `global?: true` keeps the tenant optional; the publish-gate read
  # (`Validations.RequiredConsent`, `authorize?: false`) inherits the content
  # changeset's tenant, so a consent only clears content on its own site.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped record,
    # else the default org; never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # Soft polymorphic reference to the content item (matches how the firing
    # engine / newsletter key content), not an FK.
    attribute :content_type, :string, allow_nil?: false, public?: true
    attribute :content_id, :uuid, allow_nil?: false, public?: true

    attribute :kind, :atom do
      constraints one_of: @kinds
      allow_nil? false
      public? true
    end

    # Pointer to the authorization record (ticket id / URL / document ref) —
    # NEVER the sensitive consent document itself.
    attribute :reference, :string, public?: true

    # Who granted / approved (name or role).
    attribute :grantor, :string, public?: true
    attribute :note, :string, public?: true

    attribute :granted_at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end

    # The user who recorded the consent (plain reference, no cross-domain FK).
    attribute :recorded_by_id, :uuid, public?: true

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
  end
end
