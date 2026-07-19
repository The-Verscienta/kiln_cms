defmodule KilnCMS.MultitenancyFormsWebhooksTest do
  @moduledoc """
  Tenant isolation for the forms, consent, and webhook resources (epic #336,
  PR 4c): `Form`/`FormField`/`FormSubmission`, `Consent`, `WebhookEndpoint`/
  `WebhookDelivery` are per-site.

  Proves the `:attribute` axis holds across the whole cluster: two sites can
  share a form slug, a submission lands in its form's org, a webhook dispatch
  only fans out to the publishing site's endpoints, and a consent only clears
  content on its own site.

  Not async: reads span the tables and the shared sandbox is required. Orgs are
  seeded via `Ash.Seed` to bypass the `multitenancy_enabled` create guard.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Forms
  alias KilnCMS.Webhooks

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mtfw-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org(name) do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  setup do
    %{a: org("orga"), b: org("orgb"), actor: admin()}
  end

  describe "Form slug isolation" do
    test "two orgs can share a form slug; within-org duplicate rejected",
         %{a: a, b: b, actor: actor} do
      slug = uniq("contact")

      fa = CMS.create_form!(%{name: "A", slug: slug}, actor: actor, tenant: a)
      fb = CMS.create_form!(%{name: "B", slug: slug}, actor: actor, tenant: b)

      assert fa.org_id == a.id
      assert fb.org_id == b.id

      assert {:error, _} =
               CMS.create_form(%{name: "dup", slug: slug}, actor: actor, tenant: a)
    end

    test "Forms.get_active resolves the slug within the request org", %{a: a, b: b, actor: actor} do
      slug = uniq("signup")
      CMS.create_form!(%{name: "A form", slug: slug, active: true}, actor: actor, tenant: a)

      assert %{org_id: org_id} = Forms.get_active(slug, a.id)
      assert org_id == a.id
      # Org B has no form under this slug — it must not resolve A's.
      assert Forms.get_active(slug, b.id) == nil
    end
  end

  describe "FormSubmission lands in the form's org" do
    test "a submission carries the form's org", %{a: a, actor: actor} do
      slug = uniq("contact")
      form = CMS.create_form!(%{name: "A", slug: slug, active: true}, actor: actor, tenant: a)

      CMS.create_form_field!(
        %{form_id: form.id, name: "email", label: "Email", field_type: :email},
        actor: actor,
        tenant: a
      )

      loaded = Forms.get_active(slug, a.id)
      assert {:ok, submission} = Forms.submit(loaded, %{"email" => "x@example.com"})
      assert submission.org_id == a.id
    end
  end

  describe "Webhook dispatch fans out only to the event's own site" do
    test "a dispatch for org A creates a delivery for A's endpoint, not B's",
         %{a: a, b: b, actor: actor} do
      ea =
        CMS.create_webhook_endpoint!(
          %{url: "https://a.example.com/hook", events: ["page.published"], active: true},
          actor: actor,
          tenant: a
        )

      eb =
        CMS.create_webhook_endpoint!(
          %{url: "https://b.example.com/hook", events: ["page.published"], active: true},
          actor: actor,
          tenant: b
        )

      Webhooks.dispatch("page.published", %{"id" => "x"}, a.id)

      # A's endpoint got a ledger row under A's tenant; B's got nothing.
      a_deliveries = CMS.recent_webhook_deliveries!(authorize?: false, tenant: a)
      assert Enum.any?(a_deliveries, &(&1.endpoint_id == ea.id))

      b_deliveries = CMS.recent_webhook_deliveries!(authorize?: false, tenant: b)
      refute Enum.any?(b_deliveries, &(&1.endpoint_id == eb.id))
    end
  end

  describe "Consent isolation" do
    test "list_consents_for is scoped to the reading org", %{a: a, b: b, actor: actor} do
      content_id = Ash.UUID.generate()

      CMS.record_consent!(
        %{content_type: "page", content_id: content_id, kind: :reviewer_signoff},
        actor: actor,
        tenant: a
      )

      a_kinds =
        CMS.list_consents_for!("page", content_id, authorize?: false, tenant: a)
        |> Enum.map(& &1.kind)

      assert :reviewer_signoff in a_kinds

      # The same content id under org B sees none of A's consents.
      b_consents = CMS.list_consents_for!("page", content_id, authorize?: false, tenant: b)
      assert b_consents == []
    end
  end
end
