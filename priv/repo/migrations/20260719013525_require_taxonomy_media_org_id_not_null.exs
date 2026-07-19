defmodule KilnCMS.Repo.Migrations.RequireTaxonomyMediaOrgIdNotNull do
  @moduledoc """
  Multi-tenancy rollout (epic #336), PR 4a — **step 3 of 3** for the taxonomy,
  media, and join tables. Flips `org_id` to `NOT NULL` now that
  `backfill_taxonomy_media_org` (step 2) has stamped every existing row with the
  default org. The FK added in step 1 is untouched (`SET NOT NULL` is orthogonal
  to the constraint).
  """

  use Ecto.Migration

  def up do
    alter table(:content_links) do
      modify :org_id, :uuid, null: false
    end

    alter table(:taggings) do
      modify :org_id, :uuid, null: false
    end

    alter table(:categories) do
      modify :org_id, :uuid, null: false
    end

    alter table(:media_items) do
      modify :org_id, :uuid, null: false
    end

    alter table(:tags) do
      modify :org_id, :uuid, null: false
    end
  end

  def down do
    alter table(:tags) do
      modify :org_id, :uuid, null: true
    end

    alter table(:media_items) do
      modify :org_id, :uuid, null: true
    end

    alter table(:categories) do
      modify :org_id, :uuid, null: true
    end

    alter table(:taggings) do
      modify :org_id, :uuid, null: true
    end

    alter table(:content_links) do
      modify :org_id, :uuid, null: true
    end
  end
end
