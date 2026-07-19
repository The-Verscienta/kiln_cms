defmodule KilnCMS.Repo.Migrations.RequireAnalyticsNewsletterOrgIdNotNull do
  @moduledoc """
  Multi-tenancy rollout (epic #336), PR 4d — **step 3 of 3** for the analytics,
  newsletter, history, and automation tables. Flips `org_id` to `NOT NULL` now
  that `backfill_analytics_newsletter_org` (step 2) has stamped every existing
  row with the default org. The FKs added in step 1 are untouched.
  """

  use Ecto.Migration

  def up do
    alter table(:newsletter_segments) do
      modify :org_id, :uuid, null: false
    end

    alter table(:content_views) do
      modify :org_id, :uuid, null: false
    end

    alter table(:newsletter_segment_memberships) do
      modify :org_id, :uuid, null: false
    end

    alter table(:newsletter_subscribers) do
      modify :org_id, :uuid, null: false
    end

    alter table(:automation_rules) do
      modify :org_id, :uuid, null: false
    end

    alter table(:newsletter_sends) do
      modify :org_id, :uuid, null: false
    end

    alter table(:document_events) do
      modify :org_id, :uuid, null: false
    end

    alter table(:search_queries) do
      modify :org_id, :uuid, null: false
    end
  end

  def down do
    alter table(:search_queries) do
      modify :org_id, :uuid, null: true
    end

    alter table(:document_events) do
      modify :org_id, :uuid, null: true
    end

    alter table(:newsletter_sends) do
      modify :org_id, :uuid, null: true
    end

    alter table(:automation_rules) do
      modify :org_id, :uuid, null: true
    end

    alter table(:newsletter_subscribers) do
      modify :org_id, :uuid, null: true
    end

    alter table(:newsletter_segment_memberships) do
      modify :org_id, :uuid, null: true
    end

    alter table(:content_views) do
      modify :org_id, :uuid, null: true
    end

    alter table(:newsletter_segments) do
      modify :org_id, :uuid, null: true
    end
  end
end
