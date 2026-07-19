defmodule KilnCMS.Repo.Migrations.RequireDefinitionsOrgIdNotNull do
  @moduledoc """
  Multi-tenancy rollout (epic #336), PR 4b — **step 3 of 3** for the dynamic
  type-registry tables. Flips `org_id` to `NOT NULL` now that
  `backfill_definitions_org` (step 2) has stamped every existing row with the
  default org. The FKs added in step 1 are untouched.
  """

  use Ecto.Migration

  def up do
    alter table(:field_definitions) do
      modify :org_id, :uuid, null: false
    end

    alter table(:type_definitions) do
      modify :org_id, :uuid, null: false
    end
  end

  def down do
    alter table(:type_definitions) do
      modify :org_id, :uuid, null: true
    end

    alter table(:field_definitions) do
      modify :org_id, :uuid, null: true
    end
  end
end
