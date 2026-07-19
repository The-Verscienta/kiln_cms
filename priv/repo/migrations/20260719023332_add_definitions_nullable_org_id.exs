defmodule KilnCMS.Repo.Migrations.AddDefinitionsNullableOrgId do
  @moduledoc """
  Multi-tenancy rollout (epic #336), PR 4b — **step 1 of 3** for the dynamic
  type-registry tables (`type_definitions`, `field_definitions`).

  Adds a **nullable** `org_id` (+ FK) to each and rewrites both resources'
  identities to lead with `org_id` (`(org_id, name)` / `(org_id, path_segment)`
  / `(org_id, content_type, name)` / `(org_id, type_definition_id, name)`), so a
  type/field name is unique **per site**. `org_id` stays nullable here so
  existing rows don't violate `NOT NULL`; `backfill_definitions_org` stamps them
  to the default org and `require_definitions_org_id_not_null` adds the
  constraint (same recipe as PR 1/4a). No companion lookup indexes — both tables
  are tiny admin-defined lookups, so a tenant-less seq scan is negligible.

  The `entries`/`field_definitions` → `type_definitions` FK constraints are
  dropped and re-created with **byte-identical DDL** — Ash re-emits them only
  because `type_definitions` now records a multitenancy block in its snapshot.
  """

  use Ecto.Migration

  def up do
    drop constraint(:entries, "entries_type_definition_id_fkey")

    alter table(:entries) do
      modify :type_definition_id,
             references(:type_definitions,
               column: :id,
               name: "entries_type_definition_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    drop constraint(:field_definitions, "field_definitions_type_definition_id_fkey")

    alter table(:field_definitions) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "field_definitions_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop_if_exists unique_index(:field_definitions, [:type_definition_id, :name],
                     name: "field_definitions_unique_definition_field_index"
                   )

    drop_if_exists unique_index(:field_definitions, [:content_type, :name],
                     name: "field_definitions_unique_field_index"
                   )

    create unique_index(:field_definitions, [:org_id, :type_definition_id, :name],
             name: "field_definitions_unique_definition_field_index"
           )

    create unique_index(:field_definitions, [:org_id, :content_type, :name],
             name: "field_definitions_unique_field_index"
           )

    alter table(:field_definitions) do
      modify :type_definition_id,
             references(:type_definitions,
               column: :id,
               name: "field_definitions_type_definition_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    alter table(:type_definitions) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "type_definitions_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop_if_exists unique_index(:type_definitions, [:name],
                     name: "type_definitions_unique_name_index"
                   )

    drop_if_exists unique_index(:type_definitions, [:path_segment],
                     name: "type_definitions_unique_path_segment_index"
                   )

    create unique_index(:type_definitions, [:org_id, :name],
             name: "type_definitions_unique_name_index"
           )

    create unique_index(:type_definitions, [:org_id, :path_segment],
             name: "type_definitions_unique_path_segment_index"
           )
  end

  def down do
    drop constraint(:type_definitions, "type_definitions_org_id_fkey")

    drop_if_exists unique_index(:type_definitions, [:org_id, :path_segment],
                     name: "type_definitions_unique_path_segment_index"
                   )

    drop_if_exists unique_index(:type_definitions, [:org_id, :name],
                     name: "type_definitions_unique_name_index"
                   )

    create unique_index(:type_definitions, [:path_segment],
             name: "type_definitions_unique_path_segment_index"
           )

    create unique_index(:type_definitions, [:name], name: "type_definitions_unique_name_index")

    alter table(:type_definitions) do
      remove :org_id
    end

    drop constraint(:field_definitions, "field_definitions_org_id_fkey")

    drop constraint(:field_definitions, "field_definitions_type_definition_id_fkey")

    alter table(:field_definitions) do
      modify :type_definition_id,
             references(:type_definitions,
               column: :id,
               name: "field_definitions_type_definition_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end

    drop_if_exists unique_index(:field_definitions, [:org_id, :content_type, :name],
                     name: "field_definitions_unique_field_index"
                   )

    drop_if_exists unique_index(:field_definitions, [:org_id, :type_definition_id, :name],
                     name: "field_definitions_unique_definition_field_index"
                   )

    create unique_index(:field_definitions, [:content_type, :name],
             name: "field_definitions_unique_field_index"
           )

    create unique_index(:field_definitions, [:type_definition_id, :name],
             name: "field_definitions_unique_definition_field_index"
           )

    alter table(:field_definitions) do
      remove :org_id
    end

    drop constraint(:entries, "entries_type_definition_id_fkey")

    alter table(:entries) do
      modify :type_definition_id,
             references(:type_definitions,
               column: :id,
               name: "entries_type_definition_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end
  end
end
