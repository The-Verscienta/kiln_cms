defmodule KilnCMS.Repo.Migrations.RequireFormsWebhooksOrgIdNotNull do
  @moduledoc """
  Multi-tenancy rollout (epic #336), PR 4c — **step 3 of 3** for the forms,
  consent, and webhook tables. Flips `org_id` to `NOT NULL` now that
  `backfill_forms_webhooks_org` (step 2) has stamped every existing row with the
  default org. The FKs added in step 1 are untouched.
  """

  use Ecto.Migration

  def up do
    alter table(:webhook_deliveries) do
      modify :org_id, :uuid, null: false
    end

    alter table(:form_submissions) do
      modify :org_id, :uuid, null: false
    end

    alter table(:form_fields) do
      modify :org_id, :uuid, null: false
    end

    alter table(:webhook_endpoints) do
      modify :org_id, :uuid, null: false
    end

    alter table(:forms) do
      modify :org_id, :uuid, null: false
    end

    alter table(:content_consents) do
      modify :org_id, :uuid, null: false
    end
  end

  def down do
    alter table(:content_consents) do
      modify :org_id, :uuid, null: true
    end

    alter table(:forms) do
      modify :org_id, :uuid, null: true
    end

    alter table(:webhook_endpoints) do
      modify :org_id, :uuid, null: true
    end

    alter table(:form_fields) do
      modify :org_id, :uuid, null: true
    end

    alter table(:form_submissions) do
      modify :org_id, :uuid, null: true
    end

    alter table(:webhook_deliveries) do
      modify :org_id, :uuid, null: true
    end
  end
end
