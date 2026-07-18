defmodule KilnCMS.Repo.Migrations.BackfillDefaultOrg do
  @moduledoc """
  Data migration for the multi-tenancy rollout (epic #336).

  Runs between the two schema migrations that add `org_id`:
    1. `add_organizations_and_nullable_org_id` — creates the org tables and adds
       a **nullable** `org_id` (+ FK) to every tenant-scoped table.
    2. *this migration* — seeds the sentinel **default organization**, backfills
       every existing row's `org_id` to it, and gives every existing user a
       membership in it (role/audiences/editable_types copied from the user).
    3. `require_org_id_not_null` — flips `org_id` to `NOT NULL`.

  Idempotent: safe to re-run (the insert is `ON CONFLICT DO NOTHING`, the
  backfills are `WHERE org_id IS NULL`). This is a hand-written *data* migration
  (not a schema migration) — Ash owns the schema, but a backfill can't be
  generated.
  """
  use Ecto.Migration

  # Kept in sync with `KilnCMS.Accounts.Organization.default_id/0`.
  @default_org_id "00000000-0000-0000-0000-000000000001"

  # Every tenant-scoped table whose existing rows belong to the default org.
  @scoped_tables ~w(
    pages posts entries
    pages_versions posts_versions entries_versions
    published_artifacts reference_edges block_embeddings
  )

  def up do
    # 1. The sentinel default organization every pre-existing row belongs to.
    execute("""
    INSERT INTO organizations (id, name, slug, status, inserted_at, updated_at)
    VALUES ('#{@default_org_id}', 'Default', 'default', 'active',
            now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
    ON CONFLICT (id) DO NOTHING
    """)

    # 2. Backfill every scoped row to the default org.
    for table <- @scoped_tables do
      execute("UPDATE #{table} SET org_id = '#{@default_org_id}' WHERE org_id IS NULL")
    end

    # 3. Give every existing user a membership in the default org, carrying their
    #    current role/read-axis/authoring-scope (mirrors the fields on `users`).
    execute("""
    INSERT INTO org_memberships
      (id, organization_id, user_id, role, audiences, editable_types, inserted_at, updated_at)
    SELECT gen_random_uuid(), '#{@default_org_id}', u.id,
           u.role, u.audiences, u.editable_types,
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc'
    FROM users u
    ON CONFLICT (user_id, organization_id) DO NOTHING
    """)
  end

  def down do
    # Remove the memberships in the default org, null out the backfilled column
    # (the schema migration's `down` drops the column entirely), and drop the
    # sentinel org.
    execute("DELETE FROM org_memberships WHERE organization_id = '#{@default_org_id}'")

    for table <- @scoped_tables do
      execute("UPDATE #{table} SET org_id = NULL WHERE org_id = '#{@default_org_id}'")
    end

    execute("DELETE FROM organizations WHERE id = '#{@default_org_id}'")
  end
end
