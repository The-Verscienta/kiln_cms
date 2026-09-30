defmodule KilnCMS.CMS.WebhookEndpointTest do
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "wh-val-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  alias KilnCMS.CMS.WebhookEndpoint

  describe "default events (#1776)" do
    test "a create that names no events gets the default, without draft-carrying events" do
      endpoint =
        CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin())

      assert Enum.sort(endpoint.events) == Enum.sort(WebhookEndpoint.default_events())
      assert "page.published" in endpoint.events
      assert "form.submitted" in endpoint.events

      for verb <- ~w(created in_review returned_to_draft), type <- ~w(page post) do
        refute "#{type}.#{verb}" in endpoint.events
      end

      refute Enum.any?(endpoint.events, &WebhookEndpoint.carries_drafts?/1)
    end

    test "the draft verbs are exactly created, in_review and returned_to_draft" do
      assert Enum.sort(WebhookEndpoint.draft_verbs()) ==
               ~w(created in_review returned_to_draft)

      assert WebhookEndpoint.carries_drafts?("page.in_review")
      refute WebhookEndpoint.carries_drafts?("page.published")
      refute WebhookEndpoint.carries_drafts?("task.assigned")
      refute WebhookEndpoint.carries_drafts?("ping")
    end

    test "the default follows the tenant's own dynamic types" do
      admin = admin()

      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org Webhook Defaults",
          slug: "wh-def-#{System.unique_integer([:positive])}",
          status: :active
        })

      mine = "gizmo#{System.unique_integer([:positive])}"
      CMS.create_type_definition!(%{name: mine, label: "Gizmo"}, actor: admin, tenant: org)

      endpoint =
        CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"},
          actor: admin,
          tenant: org
        )

      assert Enum.sort(endpoint.events) == Enum.sort(WebhookEndpoint.default_events(org))
      assert "#{mine}.published" in endpoint.events
      refute "#{mine}.in_review" in endpoint.events
    end

    test "explicit events, drafts or none, are kept as given" do
      admin = admin()

      opted_in =
        CMS.create_webhook_endpoint!(
          %{url: "https://example.test/a", events: ["page.in_review"]},
          actor: admin
        )

      assert opted_in.events == ["page.in_review"]

      none =
        CMS.create_webhook_endpoint!(%{url: "https://example.test/b", events: []}, actor: admin)

      assert none.events == []
    end
  end

  test "rejects private webhook URLs on create" do
    admin = admin()

    assert {:error, %Ash.Error.Invalid{}} =
             CMS.create_webhook_endpoint(%{url: "http://127.0.0.1/hook"}, actor: admin)
  end

  test "rejects private webhook URLs on update" do
    admin = admin()

    endpoint =
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    assert {:error, %Ash.Error.Invalid{}} =
             CMS.update_webhook_endpoint(endpoint, %{url: "http://192.168.0.1/hook"},
               actor: admin
             )
  end
end
