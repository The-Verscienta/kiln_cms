defmodule KilnCMS.Push.KeysTest do
  @moduledoc """
  A site's own Web Push key pair (#1560): the row (`KilnCMS.CMS.SiteVapidKey`),
  the resolver both halves of push ask (`KilnCMS.Push.Keys`), and the binding
  between a subscription and the key it was made against.

  What each group pins, because each is a way this could quietly go wrong:

    * **the row** — generated, never entered; the private half encrypted; a
      second *Generate* keeps the first pair; the subject defaults to the admin.
    * **authorization** — site admins only, and only on their own site.
    * **precedence** — a site's own key for new subscriptions, the deployment's
      for a site without one, off with neither.
    * **binding** — the key the browser was handed is the one recorded, and the
      one that signs; a subscription from before the site had its own key keeps
      the deployment's.
    * **rotation** — drops exactly the subscriptions bound to the old key, and
      one that raced it is pruned rather than signed with the wrong key.
    * **fail direction** — an undecryptable key holds that site's pushes and
      never signs with another key.
  """
  # async: false — configures the global deployment VAPID keys.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.PushSubscription
  alias KilnCMS.CMS
  alias KilnCMS.Keys.Vault
  alias KilnCMS.Push
  alias KilnCMS.Push.Keys
  alias KilnCMS.Push.Vapid
  alias KilnCMS.Push.Worker

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Push, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Push, original) end)

    %{
      org: KilnCMS.OrgFixtures.org("vapid"),
      other: KilnCMS.OrgFixtures.org("vapid-other"),
      original: original
    }
  end

  defp deployment_keys!(original) do
    {public, private} = Vapid.generate()

    Application.put_env(
      :kiln_cms,
      KilnCMS.Push,
      Keyword.merge(original,
        vapid_public_key: public,
        vapid_private_key: private,
        vapid_subject: "mailto:ops@example.com"
      )
    )

    public
  end

  defp no_deployment_keys!(original) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Push,
      Keyword.drop(original, [:vapid_public_key, :vapid_private_key, :vapid_subject])
    )
  end

  defp user(role \\ :editor) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "vapid-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp site_admin(org) do
    actor = user(:editor)

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: actor.id,
      organization_id: org.id,
      role: :admin
    })

    actor
  end

  defp generate!(org), do: CMS.generate_site_vapid_key!(%{}, tenant: org, authorize?: false)

  defp subscribe!(actor, org, opts \\ []) do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    params = %{
      "endpoint" => "https://push.example.com/x/#{System.unique_integer([:positive])}",
      "p256dh" => Base.url_encode64(public, padding: false),
      "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "label" => "Mac · Firefox"
    }

    {:ok, subscription} = Push.subscribe(params, actor, org, opts)
    subscription
  end

  defp reload(subscription),
    do:
      Accounts.get_push_subscription(subscription.id,
        authorize?: false,
        not_found_error?: false
      )

  defp run(subscription) do
    Worker.perform(%Oban.Job{
      args: %{"subscription_id" => subscription.id, "payload" => %{"title" => "t"}}
    })
  end

  # The key a delivery was signed with: the `k=` of its VAPID header.
  defp capture_signing_key do
    test_pid = self()

    Req.Test.stub(KilnCMS.Push, fn conn ->
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      ["vapid t=" <> _jwt, "k=" <> key] = String.split(authorization, ", ")
      send(test_pid, {:signed_with, key})
      Plug.Conn.send_resp(conn, 201, "")
    end)
  end

  defp refuse_any_request do
    Req.Test.stub(KilnCMS.Push, fn _conn -> flunk("no request should have been sent") end)
  end

  defp force_private_key!(row, value) do
    {1, _} =
      KilnCMS.Repo.update_all(
        from(r in "site_vapid_keys", where: r.id == type(^row.id, :binary_id)),
        set: [private_key_encrypted: value]
      )
  end

  describe "the row" do
    test "Generate mints a working pair and encrypts the private half", %{org: org} do
      row = generate!(org)

      assert {:ok, private} = Vault.decrypt(row.private_key_encrypted)
      assert {:ok, %{public_b64: public}} = Vapid.load(row.public_key, private, "mailto:a@b.c")
      assert public == row.public_key
      refute inspect(row) =~ private
    end

    test "a second Generate keeps the first pair", %{org: org} do
      first = generate!(org)
      second = generate!(org)

      assert second.public_key == first.public_key
      assert second.private_key_encrypted == first.private_key_encrypted
    end

    test "a subject edit never replaces the pair", %{org: org} do
      row = generate!(org)

      updated =
        CMS.update_site_vapid_key!(row, %{subject: "https://example.com/contact"},
          tenant: org,
          authorize?: false
        )

      assert updated.subject == "https://example.com/contact"
      assert updated.public_key == row.public_key
    end

    test "the subject defaults to the generating admin's address", %{org: org} do
      admin = site_admin(org)
      row = CMS.generate_site_vapid_key!(%{}, actor: admin, tenant: org)

      assert row.subject == "mailto:#{admin.email}"
    end

    test "a subject must be a mailto: or https: contact", %{org: org} do
      row = generate!(org)

      assert {:error, _invalid} =
               CMS.update_site_vapid_key(row, %{subject: "ops@example.com"},
                 tenant: org,
                 authorize?: false
               )
    end

    test "rotating a site with no key is refused", %{org: org} do
      row =
        Ash.Seed.seed!(CMS.SiteVapidKey, %{org_id: org.id, subject: "mailto:a@example.com"})

      assert {:error, _invalid} = CMS.rotate_site_vapid_key(row, tenant: org, authorize?: false)
    end
  end

  describe "authorization" do
    test "a site admin can generate, rotate and read their own site's key", %{org: org} do
      admin = site_admin(org)

      assert {:ok, row} = CMS.generate_site_vapid_key(%{}, actor: admin, tenant: org)
      assert {:ok, [_row]} = CMS.list_site_vapid_key(actor: admin, tenant: org)
      assert {:ok, _rotated} = CMS.rotate_site_vapid_key(row, actor: admin, tenant: org)
    end

    test "an editor of the site can do none of it", %{org: org} do
      editor = user(:editor)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        user_id: editor.id,
        organization_id: org.id,
        role: :editor
      })

      row = generate!(org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.generate_site_vapid_key(%{}, actor: editor, tenant: org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.rotate_site_vapid_key(row, actor: editor, tenant: org)

      assert {:ok, []} = CMS.list_site_vapid_key(actor: editor, tenant: org)
    end

    test "another site's admin can't touch it", %{org: org, other: other} do
      outsider = site_admin(other)
      row = generate!(org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.rotate_site_vapid_key(row, actor: outsider, tenant: org)

      assert {:ok, []} = CMS.list_site_vapid_key(actor: outsider, tenant: org)
    end
  end

  describe "precedence" do
    test "neither the site nor the deployment has a key: push is off", ctx do
      no_deployment_keys!(ctx.original)

      assert Keys.for_org(ctx.org.id) == :off
      refute Push.enabled?(ctx.org)
    end

    test "a site without its own key uses the deployment's", ctx do
      public = deployment_keys!(ctx.original)

      assert {:ok, :deployment, %{public_b64: ^public}} = Keys.for_org(ctx.org.id)
      assert Push.public_key(ctx.org) == public
    end

    test "a site with its own key hands that out, whatever the deployment has", ctx do
      deployment_keys!(ctx.original)
      row = generate!(ctx.org)

      assert {:ok, :site, %{public_b64: key}} = Keys.for_org(ctx.org.id)
      assert key == row.public_key
    end

    test "a site's own key turns push on with no deployment keys at all", ctx do
      no_deployment_keys!(ctx.original)
      row = generate!(ctx.org)

      assert Push.public_key(ctx.org) == row.public_key
    end

    test "one site's key never reaches another site", ctx do
      public = deployment_keys!(ctx.original)
      generate!(ctx.org)

      assert Push.public_key(ctx.other) == public
    end
  end

  describe "binding a subscription to its key" do
    test "a subscription on a site with its own key records it, and is signed with it", ctx do
      deployment_keys!(ctx.original)
      row = generate!(ctx.org)
      subscription = subscribe!(user(), ctx.org)

      assert subscription.vapid_public_key == row.public_key

      capture_signing_key()
      assert :ok = run(subscription)
      assert_received {:signed_with, key}
      assert key == row.public_key
    end

    test "a subscription made against the deployment's key records none", ctx do
      deployment_keys!(ctx.original)
      subscription = subscribe!(user(), ctx.org)

      assert subscription.vapid_public_key == nil
    end

    test "a subscription from before the site had its own key keeps the deployment's", ctx do
      deployment = deployment_keys!(ctx.original)
      actor = user()
      before = subscribe!(actor, ctx.org)

      # The site admin presses Generate afterwards.
      row = generate!(ctx.org)
      new = subscribe!(actor, ctx.org)

      capture_signing_key()

      assert :ok = run(before)
      assert_received {:signed_with, old_key}
      assert old_key == deployment

      assert :ok = run(new)
      assert_received {:signed_with, new_key}
      assert new_key == row.public_key
    end

    test "a key the page handed out before a rotation is refused, not stored", ctx do
      row = generate!(ctx.org)
      handed_out = row.public_key
      CMS.rotate_site_vapid_key!(row, tenant: ctx.org, authorize?: false)

      {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

      params = %{
        "endpoint" => "https://push.example.com/x/raced",
        "p256dh" => Base.url_encode64(public, padding: false),
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }

      assert {:error, :stale_key} =
               Push.subscribe(params, user(), ctx.org, public_key: handed_out)
    end

    test "notify skips deployment-key subscriptions with no deployment keys, not site ones",
         ctx do
      deployment_keys!(ctx.original)
      actor = user()
      subscribe!(actor, ctx.org)
      generate!(ctx.org)
      site_bound = subscribe!(actor, ctx.org)

      no_deployment_keys!(ctx.original)
      Push.notify([actor], %{"title" => "t"})

      assert [job] =
               Oban.Job |> KilnCMS.Repo.all() |> Enum.filter(&(&1.worker =~ "Push.Worker"))

      assert job.args["subscription_id"] == site_bound.id
    end
  end

  describe "rotation" do
    test "drops exactly the subscriptions bound to the old key", ctx do
      deployment_keys!(ctx.original)
      actor = user()

      env_bound = subscribe!(actor, ctx.org)
      row = generate!(ctx.org)
      site_bound = subscribe!(actor, ctx.org)

      other_row = generate!(ctx.other)
      other_site = subscribe!(actor, ctx.other)
      assert other_site.vapid_public_key == other_row.public_key

      rotated = CMS.rotate_site_vapid_key!(row, tenant: ctx.org, authorize?: false)

      refute rotated.public_key == row.public_key
      assert {:ok, nil} = reload(site_bound)
      assert {:ok, %PushSubscription{}} = reload(env_bound)
      assert {:ok, %PushSubscription{}} = reload(other_site)

      # And new subscriptions bind to the new key.
      assert subscribe!(actor, ctx.org).vapid_public_key == rotated.public_key
    end

    test "removing the key drops its subscriptions too", ctx do
      row = generate!(ctx.org)
      subscription = subscribe!(user(), ctx.org)

      CMS.reset_site_vapid_key!(row, tenant: ctx.org, authorize?: false)

      assert {:ok, nil} = reload(subscription)
    end

    test "a subscription that raced a rotation is pruned, never signed with the new key", ctx do
      row = generate!(ctx.org)
      subscription = subscribe!(user(), ctx.org)

      # The key changed without the rotation's sweep reaching this row.
      {public, private} = Vapid.generate()

      Ash.Seed.update!(row, %{
        public_key: public,
        private_key_encrypted: Vault.encrypt(private)
      })

      refuse_any_request()
      assert :ok = run(subscription)
      assert {:ok, nil} = reload(subscription)
    end
  end

  describe "fail direction" do
    test "an undecryptable site key holds the push and keeps the subscription", ctx do
      deployment_keys!(ctx.original)
      row = generate!(ctx.org)
      subscription = subscribe!(user(), ctx.org)

      # What a SECRET_KEY_BASE rotation leaves behind.
      force_private_key!(row, :crypto.strong_rand_bytes(64))

      refuse_any_request()

      capture_log(fn ->
        assert {:error, :key_unreadable} = run(subscription)
      end)

      assert {:ok, %PushSubscription{}} = reload(subscription)
    end

    test "the subscribe side offers no key rather than one whose private half is gone", ctx do
      deployment_keys!(ctx.original)
      row = generate!(ctx.org)
      force_private_key!(row, :crypto.strong_rand_bytes(64))

      assert {:error, :key_unreadable} = Keys.for_org(ctx.org.id)
      assert Push.public_key(ctx.org) == nil

      [reread] = CMS.list_site_vapid_key!(tenant: ctx.org, authorize?: false)
      refute Keys.private_key_readable?(reread)
    end

    test "a row that can't be read holds rather than falling back to the deployment's key",
         ctx do
      deployment_keys!(ctx.original)

      capture_log(fn ->
        assert {:error, :unavailable} = Keys.for_org("not-an-org-id")

        assert {:error, :unavailable} =
                 Keys.for_subscription(%{org_id: "not-an-org-id", vapid_public_key: "B"})
      end)
    end
  end
end
