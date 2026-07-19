defmodule KilnCMS.Repo.Migrations.BackfillFormsWebhooksOrg do
  @moduledoc """
  Data migration for the multi-tenancy rollout (epic #336), PR 4c — **step 2 of
  3** for the forms, consent, and webhook tables.

  Runs between the two schema migrations that add `org_id`:
    1. `add_forms_webhooks_nullable_org_id` — adds the **nullable** `org_id`.
    2. *this migration* — backfills every existing row's `org_id` to the sentinel
       default organization (seeded by the PR-1 `backfill_default_org` migration).
    3. `require_forms_webhooks_org_id_not_null` — flips `org_id` to `NOT NULL`.

  Idempotent (`WHERE org_id IS NULL`). Hand-written *data* migration — Ash owns
  the schema, but a backfill can't be generated.
  """
  use Ecto.Migration

  # Kept in sync with `KilnCMS.Accounts.Organization.default_id/0`.
  @default_org_id "00000000-0000-0000-0000-000000000001"

  @scoped_tables ~w(
    forms form_fields form_submissions
    content_consents webhook_endpoints webhook_deliveries
  )

  def up do
    for table <- @scoped_tables do
      execute("UPDATE #{table} SET org_id = '#{@default_org_id}' WHERE org_id IS NULL")
    end
  end

  def down do
    for table <- @scoped_tables do
      execute("UPDATE #{table} SET org_id = NULL WHERE org_id = '#{@default_org_id}'")
    end
  end
end
