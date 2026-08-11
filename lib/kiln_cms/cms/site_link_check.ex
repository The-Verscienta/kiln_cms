defmodule KilnCMS.CMS.SiteLinkCheck do
  @moduledoc """
  Whether this site checks its **outbound** links, and when it last did (#474).

  Off by default, and the row exists so that saying "on" is a deliberate,
  attributable act rather than a deployment-wide default. Turning it on makes
  the server issue requests to every third-party URL the site's published
  content points at — on a schedule, without anyone watching. Some deployments
  cannot do that at all (an air-gapped install, an egress policy), and none
  should discover it from a firewall log.

  The internal half of the link checker (`KilnCMS.Links.Internal`) has no switch
  and needs none: it is a database query, it runs in the editor, and it costs a
  reader nothing.

  ## One row per site, absent until saved

  Absence *is* the default, so nothing creates a row on a read — the reader
  (`KilnCMS.Links.Settings`) resolves a missing row to "disabled" rather than
  writing one. That keeps a report page for a site that has never been
  configured from being a write.

  `last_swept_at` is written by the sweep, not by a human, which is why it is
  not in `default_accept`: a settings form that could backdate it would make the
  report's "checked as of" line say whatever the last person to save wanted.
  """
  use Ash.Resource,
    domain: KilnCMS.CMS,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "site_link_check"
    repo KilnCMS.Repo
  end

  actions do
    defaults [:read]

    default_accept [:external_enabled]

    create :save do
      primary? true
      upsert? true
      upsert_identity :one_per_org
      upsert_fields [:external_enabled]
    end

    # Written by `KilnCMS.Links.Sweep` when a run finishes, system-side. Its own
    # action rather than a field on `:save` so no settings form can reach it.
    update :record_sweep do
      require_atomic? false
      accept []
      change set_attribute(:last_swept_at, &DateTime.utc_now/0)
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  policies do
    # Editors read it: the report page shows whether checking is on, and an
    # editor looking at an empty report deserves to know it is empty because
    # nothing has run rather than because nothing is broken.
    policy action_type(:read) do
      authorize_if KilnCMS.CMS.Checks.OrgEditor
    end

    # Deciding that this deployment makes outbound requests is an admin act.
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

    attribute :external_enabled, :boolean do
      default false
      allow_nil? false
      public? true
    end

    # When the last sweep finished for this site. `nil` means never — which the
    # report shows as "not yet run" rather than as a clean bill of health.
    attribute :last_swept_at, :utc_datetime_usec do
      writable? false
      public? true
    end

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
    identity :one_per_org, [:org_id]
  end
end
