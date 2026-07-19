defmodule KilnCMS.Repo.Migrations.AddAnalyticsNewsletterNullableOrgId do
  @moduledoc """
  Multi-tenancy rollout (epic #336), PR 4d — **step 1 of 3** for the analytics,
  newsletter, history, and automation tables (`content_views`, `search_queries`,
  `document_events`, `automation_rules`, `newsletter_subscribers`,
  `newsletter_segments`, `newsletter_segment_memberships`, `newsletter_sends`).

  Adds a **nullable** `org_id` (+ FK) to each and rewrites the affected
  identities to lead with `org_id` — including the two upsert targets
  (`content_views (org_id, content_type, content_id)`,
  `search_queries (org_id, query, locale)`), so per-site counters never collide.
  Each identity keeps its **name** (only its columns change), so the
  `document_events_doc_seq_index` reference in `KilnCMS.History` stays valid.
  `org_id` stays nullable here so existing rows don't violate `NOT NULL`;
  `backfill_analytics_newsletter_org` stamps them to the default org and
  `require_analytics_newsletter_org_id_not_null` adds the constraint. No
  companion indexes. The FK re-emissions on `newsletter_*` join columns are
  byte-identical DDL (referenced tables gained a multitenancy snapshot).
  """

  use Ecto.Migration

  def up do
    alter table(:newsletter_segments) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "newsletter_segments_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop_if_exists unique_index(:newsletter_segments, [:slug],
                     name: "newsletter_segments_unique_slug_index"
                   )

    create unique_index(:newsletter_segments, [:org_id, :slug],
             name: "newsletter_segments_unique_slug_index"
           )

    alter table(:content_views) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "content_views_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop_if_exists unique_index(:content_views, [:content_type, :content_id],
                     name: "content_views_unique_content_index"
                   )

    create unique_index(:content_views, [:org_id, :content_type, :content_id],
             name: "content_views_unique_content_index"
           )

    drop constraint(
           :newsletter_segment_memberships,
           "newsletter_segment_memberships_subscriber_id_fkey"
         )

    drop constraint(
           :newsletter_segment_memberships,
           "newsletter_segment_memberships_segment_id_fkey"
         )

    alter table(:newsletter_segment_memberships) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "newsletter_segment_memberships_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop_if_exists unique_index(:newsletter_segment_memberships, [:segment_id, :subscriber_id],
                     name: "newsletter_segment_memberships_unique_membership_index"
                   )

    create unique_index(:newsletter_segment_memberships, [:org_id, :segment_id, :subscriber_id],
             name: "newsletter_segment_memberships_unique_membership_index"
           )

    alter table(:newsletter_segment_memberships) do
      modify :segment_id,
             references(:newsletter_segments,
               column: :id,
               name: "newsletter_segment_memberships_segment_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )

      modify :subscriber_id,
             references(:newsletter_subscribers,
               column: :id,
               name: "newsletter_segment_memberships_subscriber_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )
    end

    alter table(:newsletter_subscribers) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "newsletter_subscribers_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop_if_exists unique_index(:newsletter_subscribers, [:email],
                     name: "newsletter_subscribers_unique_email_index"
                   )

    create unique_index(:newsletter_subscribers, [:org_id, :email],
             name: "newsletter_subscribers_unique_email_index"
           )

    alter table(:automation_rules) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "automation_rules_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop constraint(:newsletter_sends, "newsletter_sends_segment_id_fkey")

    alter table(:newsletter_sends) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "newsletter_sends_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )

      modify :segment_id,
             references(:newsletter_segments,
               column: :id,
               name: "newsletter_sends_segment_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :nilify_all
             )
    end

    alter table(:document_events) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "document_events_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop_if_exists unique_index(:document_events, [:document_type, :document_id, :seq],
                     name: "document_events_doc_seq_index"
                   )

    create unique_index(:document_events, [:org_id, :document_type, :document_id, :seq],
             name: "document_events_doc_seq_index"
           )

    alter table(:search_queries) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "search_queries_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop_if_exists unique_index(:search_queries, [:query, :locale],
                     name: "search_queries_unique_query_index"
                   )

    create unique_index(:search_queries, [:org_id, :query, :locale],
             name: "search_queries_unique_query_index"
           )
  end

  def down do
    drop constraint(:search_queries, "search_queries_org_id_fkey")

    drop_if_exists unique_index(:search_queries, [:org_id, :query, :locale],
                     name: "search_queries_unique_query_index"
                   )

    create unique_index(:search_queries, [:query, :locale],
             name: "search_queries_unique_query_index"
           )

    alter table(:search_queries) do
      remove :org_id
    end

    drop constraint(:document_events, "document_events_org_id_fkey")

    drop_if_exists unique_index(:document_events, [:org_id, :document_type, :document_id, :seq],
                     name: "document_events_doc_seq_index"
                   )

    create unique_index(:document_events, [:document_type, :document_id, :seq],
             name: "document_events_doc_seq_index"
           )

    alter table(:document_events) do
      remove :org_id
    end

    drop constraint(:newsletter_sends, "newsletter_sends_org_id_fkey")

    drop constraint(:newsletter_sends, "newsletter_sends_segment_id_fkey")

    alter table(:newsletter_sends) do
      modify :segment_id,
             references(:newsletter_segments,
               column: :id,
               name: "newsletter_sends_segment_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :nilify_all
             )

      remove :org_id
    end

    drop constraint(:automation_rules, "automation_rules_org_id_fkey")

    alter table(:automation_rules) do
      remove :org_id
    end

    drop constraint(:newsletter_subscribers, "newsletter_subscribers_org_id_fkey")

    drop_if_exists unique_index(:newsletter_subscribers, [:org_id, :email],
                     name: "newsletter_subscribers_unique_email_index"
                   )

    create unique_index(:newsletter_subscribers, [:email],
             name: "newsletter_subscribers_unique_email_index"
           )

    alter table(:newsletter_subscribers) do
      remove :org_id
    end

    drop constraint(:newsletter_segment_memberships, "newsletter_segment_memberships_org_id_fkey")

    drop constraint(
           :newsletter_segment_memberships,
           "newsletter_segment_memberships_segment_id_fkey"
         )

    drop constraint(
           :newsletter_segment_memberships,
           "newsletter_segment_memberships_subscriber_id_fkey"
         )

    alter table(:newsletter_segment_memberships) do
      modify :subscriber_id,
             references(:newsletter_subscribers,
               column: :id,
               name: "newsletter_segment_memberships_subscriber_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )

      modify :segment_id,
             references(:newsletter_segments,
               column: :id,
               name: "newsletter_segment_memberships_segment_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )
    end

    drop_if_exists unique_index(
                     :newsletter_segment_memberships,
                     [:org_id, :segment_id, :subscriber_id],
                     name: "newsletter_segment_memberships_unique_membership_index"
                   )

    create unique_index(:newsletter_segment_memberships, [:segment_id, :subscriber_id],
             name: "newsletter_segment_memberships_unique_membership_index"
           )

    alter table(:newsletter_segment_memberships) do
      remove :org_id
    end

    drop constraint(:content_views, "content_views_org_id_fkey")

    drop_if_exists unique_index(:content_views, [:org_id, :content_type, :content_id],
                     name: "content_views_unique_content_index"
                   )

    create unique_index(:content_views, [:content_type, :content_id],
             name: "content_views_unique_content_index"
           )

    alter table(:content_views) do
      remove :org_id
    end

    drop constraint(:newsletter_segments, "newsletter_segments_org_id_fkey")

    drop_if_exists unique_index(:newsletter_segments, [:org_id, :slug],
                     name: "newsletter_segments_unique_slug_index"
                   )

    create unique_index(:newsletter_segments, [:slug],
             name: "newsletter_segments_unique_slug_index"
           )

    alter table(:newsletter_segments) do
      remove :org_id
    end
  end
end
