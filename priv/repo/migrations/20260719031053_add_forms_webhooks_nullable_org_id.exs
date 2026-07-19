defmodule KilnCMS.Repo.Migrations.AddFormsWebhooksNullableOrgId do
  @moduledoc """
  Multi-tenancy rollout (epic #336), PR 4c — **step 1 of 3** for the forms,
  consent, and webhook tables (`forms`, `form_fields`, `form_submissions`,
  `content_consents`, `webhook_endpoints`, `webhook_deliveries`).

  Adds a **nullable** `org_id` (+ FK) to each and rewrites the affected
  identities to lead with `org_id` (`forms (org_id, slug)`,
  `form_fields (org_id, form_id, name)`), so a form slug is unique **per site**.
  `org_id` stays nullable here so existing rows don't violate `NOT NULL`;
  `backfill_forms_webhooks_org` stamps them to the default org and
  `require_forms_webhooks_org_id_not_null` adds the constraint (same recipe as
  PR 1/4a/4b). No companion indexes — these are small admin/operational tables.

  The `endpoint_id`/`form_id` FK constraints are dropped and re-created with
  **byte-identical DDL** — Ash re-emits them only because their referenced
  tables (`webhook_endpoints`/`forms`) now record a multitenancy block.
  """

  use Ecto.Migration

  def up do
    drop constraint(:webhook_deliveries, "webhook_deliveries_endpoint_id_fkey")

    alter table(:webhook_deliveries) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "webhook_deliveries_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )

      modify :endpoint_id,
             references(:webhook_endpoints,
               column: :id,
               name: "webhook_deliveries_endpoint_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )
    end

    drop constraint(:form_submissions, "form_submissions_form_id_fkey")

    alter table(:form_submissions) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "form_submissions_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )

      modify :form_id,
             references(:forms,
               column: :id,
               name: "form_submissions_form_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )
    end

    drop constraint(:form_fields, "form_fields_form_id_fkey")

    alter table(:form_fields) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "form_fields_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop_if_exists unique_index(:form_fields, [:form_id, :name],
                     name: "form_fields_unique_form_field_index"
                   )

    create unique_index(:form_fields, [:org_id, :form_id, :name],
             name: "form_fields_unique_form_field_index"
           )

    alter table(:form_fields) do
      modify :form_id,
             references(:forms,
               column: :id,
               name: "form_fields_form_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )
    end

    alter table(:webhook_endpoints) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "webhook_endpoints_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    alter table(:forms) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "forms_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    drop_if_exists unique_index(:forms, [:slug], name: "forms_unique_slug_index")

    create unique_index(:forms, [:org_id, :slug], name: "forms_unique_slug_index")

    alter table(:content_consents) do
      add :org_id,
          references(:organizations,
            column: :id,
            name: "content_consents_org_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end
  end

  def down do
    drop constraint(:content_consents, "content_consents_org_id_fkey")

    alter table(:content_consents) do
      remove :org_id
    end

    drop constraint(:forms, "forms_org_id_fkey")

    drop_if_exists unique_index(:forms, [:org_id, :slug], name: "forms_unique_slug_index")

    create unique_index(:forms, [:slug], name: "forms_unique_slug_index")

    alter table(:forms) do
      remove :org_id
    end

    drop constraint(:webhook_endpoints, "webhook_endpoints_org_id_fkey")

    alter table(:webhook_endpoints) do
      remove :org_id
    end

    drop constraint(:form_fields, "form_fields_org_id_fkey")

    drop constraint(:form_fields, "form_fields_form_id_fkey")

    alter table(:form_fields) do
      modify :form_id,
             references(:forms,
               column: :id,
               name: "form_fields_form_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )
    end

    drop_if_exists unique_index(:form_fields, [:org_id, :form_id, :name],
                     name: "form_fields_unique_form_field_index"
                   )

    create unique_index(:form_fields, [:form_id, :name],
             name: "form_fields_unique_form_field_index"
           )

    alter table(:form_fields) do
      remove :org_id
    end

    drop constraint(:form_submissions, "form_submissions_org_id_fkey")

    drop constraint(:form_submissions, "form_submissions_form_id_fkey")

    alter table(:form_submissions) do
      modify :form_id,
             references(:forms,
               column: :id,
               name: "form_submissions_form_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )

      remove :org_id
    end

    drop constraint(:webhook_deliveries, "webhook_deliveries_org_id_fkey")

    drop constraint(:webhook_deliveries, "webhook_deliveries_endpoint_id_fkey")

    alter table(:webhook_deliveries) do
      modify :endpoint_id,
             references(:webhook_endpoints,
               column: :id,
               name: "webhook_deliveries_endpoint_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :delete_all
             )

      remove :org_id
    end
  end
end
