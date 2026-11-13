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

  describe "rotate_secret (#2347)" do
    defp endpoint!(admin, opts \\ []) do
      CMS.create_webhook_endpoint!(
        %{url: "https://example.test/hook"},
        [actor: admin] ++ opts
      )
    end

    defp user(role) do
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "wh-rot-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: role
      })
    end

    test "an admin gets a new secret and the rest of the endpoint is untouched" do
      admin = admin()
      endpoint = endpoint!(admin)
      old = WebhookEndpoint.secret(endpoint)
      assert is_binary(old)

      stale = Ash.Seed.update!(endpoint, %{consecutive_failures: 3})

      rotated = CMS.rotate_webhook_secret!(stale, actor: admin)

      new = WebhookEndpoint.secret(rotated)
      assert is_binary(new) and new != old
      assert rotated.id == endpoint.id
      assert rotated.inserted_at == endpoint.inserted_at
      assert rotated.url == endpoint.url
      assert rotated.events == endpoint.events
      assert rotated.consecutive_failures == 3

      reloaded = CMS.get_webhook_endpoint!(endpoint.id, actor: admin)
      assert WebhookEndpoint.secret(reloaded) == new
    end

    test "editor, viewer, anonymous and the delivery pipeline are refused" do
      admin = admin()
      endpoint = endpoint!(admin)
      old = WebhookEndpoint.secret(endpoint)

      for actor <- [user(:editor), user(:viewer), nil, KilnCMS.Webhooks.system()] do
        refute CMS.can_rotate_webhook_secret?(actor, endpoint)

        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.rotate_webhook_secret(endpoint, actor: actor)
      end

      reloaded = CMS.get_webhook_endpoint!(endpoint.id, actor: admin)
      assert WebhookEndpoint.secret(reloaded) == old
    end

    test "an admin of another org cannot rotate" do
      admin = admin()

      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org Rotate",
          slug: "wh-rot-#{System.unique_integer([:positive])}",
          status: :active
        })

      endpoint = endpoint!(admin, tenant: org)
      old = WebhookEndpoint.secret(endpoint)
      other = admin()

      # Acting in their own site (the console always passes the request's
      # tenant), the other org's endpoint is out of reach.
      own = KilnCMS.Accounts.default_org_id()

      assert {:error, _} = CMS.rotate_webhook_secret(endpoint, actor: other, tenant: own)

      reloaded = CMS.get_webhook_endpoint!(endpoint.id, actor: admin, tenant: org)
      assert WebhookEndpoint.secret(reloaded) == old
    end

    test "a url passed to the action is rejected and the url is unchanged" do
      admin = admin()
      endpoint = endpoint!(admin)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.rotate_webhook_secret(endpoint, %{url: "https://evil.test/x"}, actor: admin)

      reloaded = CMS.get_webhook_endpoint!(endpoint.id, actor: admin)
      assert reloaded.url == "https://example.test/hook"
    end

    test "an endpoint whose ciphertext no longer opens can be rotated" do
      admin = admin()
      endpoint = endpoint!(admin)
      broken = Ash.Seed.update!(endpoint, %{secret_encrypted: "not-a-ciphertext"})
      assert WebhookEndpoint.secret(broken) == nil

      rotated = CMS.rotate_webhook_secret!(broken, actor: admin)
      assert is_binary(WebhookEndpoint.secret(rotated))
    end
  end

  describe "security events (#2245)" do
    test "a site's endpoint can subscribe to the site alert kinds and the silencing notice" do
      events = WebhookEndpoint.events()

      for kind <- KilnCMS.Security.Alerts.site_kinds(),
          do: assert("security.#{kind}" in events)

      assert "security.alerts_silenced" in events
      assert WebhookEndpoint.security_events() == KilnCMS.Security.Alerts.webhook_events()
    end

    test "platform kinds are not webhook events, and none is subscribed by default" do
      events = WebhookEndpoint.events()

      for kind <- [:platform_role_changed, :new_api_key, :api_key_abuse, :api_key_rate_limited],
          do: refute("security.#{kind}" in events)

      refute Enum.any?(WebhookEndpoint.default_events(), &String.starts_with?(&1, "security."))
    end

    test "they are domain events, reserving the `security` namespace" do
      assert "security.lockout" in WebhookEndpoint.domain_events()
      assert "security" in WebhookEndpoint.reserved_namespaces()
    end
  end

  describe "format (#2245)" do
    defp member(role) do
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "wh-fmt-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: role
      })
    end

    test "an endpoint is Kiln-format unless created otherwise" do
      endpoint = CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin())

      assert endpoint.format == :kiln
    end

    test "an admin can create a Slack-format endpoint" do
      endpoint =
        CMS.create_webhook_endpoint!(
          %{
            url: "https://hooks.example.test/services/T0/B0/abc",
            format: :slack,
            events: WebhookEndpoint.security_events()
          },
          actor: admin()
        )

      assert endpoint.format == :slack
    end

    test "a format outside kiln and slack is refused" do
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_webhook_endpoint(
                 %{url: "https://example.test/hook", format: :teams},
                 actor: admin()
               )
    end

    test "an update cannot change the format, and leaves it as it was" do
      admin = admin()
      endpoint = CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_webhook_endpoint(endpoint, %{format: :slack}, actor: admin)

      assert CMS.get_webhook_endpoint!(endpoint.id, actor: admin).format == :kiln
    end

    test "editor, viewer, anonymous and the delivery pipeline cannot create one" do
      for actor <- [member(:editor), member(:viewer), nil, KilnCMS.Webhooks.system()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.create_webhook_endpoint(
                   %{url: "https://example.test/hook", format: :slack},
                   actor: actor
                 )
      end
    end

    test "an admin of another org cannot create one in this site" do
      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Org Format",
          slug: "wh-fmt-#{System.unique_integer([:positive])}",
          status: :active
        })

      other = member(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: other.id,
        organization_id: org.id,
        role: :admin,
        status: :active
      })

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_webhook_endpoint(
                 %{url: "https://example.test/hook", format: :slack},
                 actor: other,
                 tenant: KilnCMS.Accounts.default_org_id()
               )
    end
  end

  describe "a Slack endpoint takes security events only (#2245)" do
    @slack_url "https://hooks.example.test/services/T0/B0/abcdefgh"

    defp event_errors(error) do
      for %Ash.Error.Changes.InvalidAttribute{field: :events, message: message} <- error.errors,
          do: message
    end

    test "created without events, it takes every security event" do
      endpoint =
        CMS.create_webhook_endpoint!(%{url: @slack_url, format: :slack}, actor: admin())

      assert Enum.sort(endpoint.events) == Enum.sort(WebhookEndpoint.security_events())
    end

    test "created with a content event, it is refused" do
      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_webhook_endpoint(
                 %{
                   url: @slack_url,
                   format: :slack,
                   events: ["security.lockout", "page.published"]
                 },
                 actor: admin()
               )

      assert event_errors(error) == ["Slack endpoints can only receive security events"]
    end

    test "updated to take a content event, it is refused and keeps its events" do
      admin = admin()

      endpoint =
        CMS.create_webhook_endpoint!(
          %{url: @slack_url, format: :slack, events: ["security.lockout"]},
          actor: admin
        )

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.update_webhook_endpoint(
                 endpoint,
                 %{events: ["security.lockout", "page.published"]},
                 actor: admin
               )

      assert event_errors(error) == ["Slack endpoints can only receive security events"]
      assert CMS.get_webhook_endpoint!(endpoint.id, actor: admin).events == ["security.lockout"]
    end

    # By prefix: a kind a later release adds is a security event too.
    test "a security event this release does not list is allowed" do
      endpoint =
        CMS.create_webhook_endpoint!(
          %{url: @slack_url, format: :slack, events: ["security.some_future_kind"]},
          actor: admin()
        )

      assert endpoint.events == ["security.some_future_kind"]
    end

    test "an update that leaves the events alone is not checked" do
      admin = admin()

      endpoint =
        CMS.create_webhook_endpoint!(%{url: @slack_url, format: :slack}, actor: admin)

      # A row from before the rule (raw: the action would refuse it).
      endpoint = Ash.Seed.update!(endpoint, %{events: ["page.published"]})

      assert {:ok, %{active: false}} =
               CMS.update_webhook_endpoint(endpoint, %{active: false}, actor: admin)
    end

    test "a Kiln endpoint may take content and security events together" do
      endpoint =
        CMS.create_webhook_endpoint!(
          %{url: @slack_url, events: ["security.lockout", "page.published"]},
          actor: admin()
        )

      assert endpoint.format == :kiln
    end
  end

  # `KnownAtom` (docs/releasing.md): a format a later release adds loads
  # after a rollback instead of failing every read of the table.
  test "a format this release does not know loads as UnknownAtom" do
    admin = admin()
    endpoint = CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    KilnCMS.Repo.query!(
      "UPDATE webhook_endpoints SET format = 'teams' WHERE id = $1::text::uuid",
      [
        endpoint.id
      ]
    )

    assert %KilnCMS.Types.UnknownAtom{value: "teams"} =
             CMS.get_webhook_endpoint!(endpoint.id, actor: admin).format
  end

  test "an invalid URL's error does not carry the URL (#2245)" do
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             CMS.create_webhook_endpoint(%{url: "http://localhost/s3cr3tT0ken"}, actor: admin())

    assert [%Ash.Error.Changes.InvalidAttribute{field: :url, value: nil}] =
             Enum.filter(errors, &match?(%Ash.Error.Changes.InvalidAttribute{field: :url}, &1))

    refute inspect(errors) =~ "s3cr3tT0ken"
  end

  describe "the URL is sensitive (#2245)" do
    test "inspecting an endpoint does not show its URL" do
      endpoint =
        CMS.create_webhook_endpoint!(
          %{url: "https://hooks.example.test/services/T0/B0/s3cr3tT0ken"},
          actor: admin()
        )

      refute inspect(endpoint) =~ "s3cr3tT0ken"
    end

    test "inspecting a delivery does not show its endpoint URL snapshot" do
      delivery =
        struct(KilnCMS.CMS.WebhookDelivery,
          endpoint_url: "https://hooks.example.test/services/T0/B0/s3cr3tT0ken"
        )

      refute inspect(delivery) =~ "s3cr3tT0ken"
    end
  end
end
