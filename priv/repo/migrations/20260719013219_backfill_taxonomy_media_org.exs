defmodule KilnCMS.Repo.Migrations.BackfillTaxonomyMediaOrg do
  @moduledoc """
  Data migration for the multi-tenancy rollout (epic #336), PR 4a — **step 2 of
  3** for the taxonomy, media, and join tables.

  Runs between the two schema migrations that add `org_id` to
  `categories`/`tags`/`taggings`/`content_links`/`media_items`:
    1. `add_taxonomy_media_nullable_org_id` — adds the **nullable** `org_id`.
    2. *this migration* — backfills every existing row's `org_id` to the sentinel
       default organization (already seeded by the PR-1 `backfill_default_org`
       migration, so no org insert is needed here).
    3. `require_taxonomy_media_org_id_not_null` — flips `org_id` to `NOT NULL`.

  Idempotent: the backfills are scoped `WHERE org_id IS NULL`. Hand-written
  *data* migration — Ash owns the schema, but a backfill can't be generated.
  """
  use Ecto.Migration

  # Kept in sync with `KilnCMS.Accounts.Organization.default_id/0`.
  @default_org_id "00000000-0000-0000-0000-000000000001"

  # The PR-4a tenant-scoped tables whose existing rows belong to the default org.
  @scoped_tables ~w(categories tags taggings content_links media_items)

  def up do
    for table <- @scoped_tables do
      execute("UPDATE #{table} SET org_id = '#{@default_org_id}' WHERE org_id IS NULL")
    end
  end

  def down do
    # The schema migration's `down` drops the column entirely; just null out the
    # backfilled value so a partial rollback leaves no dangling default-org refs.
    for table <- @scoped_tables do
      execute("UPDATE #{table} SET org_id = NULL WHERE org_id = '#{@default_org_id}'")
    end
  end
end
