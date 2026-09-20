defmodule KilnCMS.Federation.RekeyTest do
  @moduledoc """
  Re-keying a site's ActivityPub actor (#1487): `SiteFederation`'s `:rekey`.

  What it must keep is the identity (the origin, the username, and so the actor
  id and `keyId`), because that is what every follower holds. What it must
  replace is both halves of the key. Then it has to *tell* followers: an actor
  `Update`, queued in the same transaction and signed with the **new** key, so
  a peer that re-fetches on a failed signature finds the key that verifies it.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.Accounts.User
  alias KilnCMS.Federation
  alias KilnCMS.Federation.ActorUpdateWorker
  alias KilnCMS.Federation.Delivery
  alias KilnCMS.Federation.DeliveryWorker
  alias KilnCMS.Federation.HttpSignature
  alias KilnCMS.Federation.SiteFederation
  alias KilnCMS.FederationFixtures

  @remote "https://remote.example/users/alice"

  setup do
    FederationFixtures.enable_deployment!()
    org_id = KilnCMS.Accounts.default_org_id()
    settings = FederationFixtures.enable_site!(org_id)

    {:ok, follower} =
      Federation.follow(@remote, @remote <> "/inbox", %{}, authorize?: false, tenant: org_id)

    %{org_id: org_id, settings: settings, follower: follower}
  end

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "rekey-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp reload(settings, org_id), do: Ash.reload!(settings, authorize?: false, tenant: org_id)

  describe "who may re-key" do
    test "an admin replaces both key halves and keeps the identity", ctx do
      assert {:ok, rekeyed} =
               Federation.rekey_site_federation(ctx.settings,
                 actor: user(:admin),
                 tenant: ctx.org_id
               )

      # The identity followers hold is untouched...
      assert rekeyed.id == ctx.settings.id
      assert rekeyed.origin == ctx.settings.origin
      assert rekeyed.username == ctx.settings.username
      assert rekeyed.enabled

      # ...and both halves of the key are new, and belong together.
      refute rekeyed.public_key_pem == ctx.settings.public_key_pem
      refute rekeyed.private_key_encrypted == ctx.settings.private_key_encrypted
      new_private = SiteFederation.private_key_pem(rekeyed)
      refute new_private == SiteFederation.private_key_pem(ctx.settings)

      assert {:ok, private_key} = KilnCMS.Keys.rsa_private_key(new_private)
      # (The `:string` column stores the PEM trimmed.)
      assert String.trim(KilnCMS.Keys.rsa_public_key_pem(private_key)) == rekeyed.public_key_pem
    end

    test "an editor is refused, and the key is unchanged", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Federation.rekey_site_federation(ctx.settings,
                 actor: user(:editor),
                 tenant: ctx.org_id
               )

      assert reload(ctx.settings, ctx.org_id).public_key_pem == ctx.settings.public_key_pem
      refute_enqueued(worker: ActorUpdateWorker)
    end

    test "a site that was never enabled has no identity to re-key" do
      org = KilnCMS.OrgFixtures.org("rekeynever")

      # `:save` creates the row (a profile edit) without minting an identity.
      {:ok, bare} =
        Federation.save_site_federation(%{display_name: "Not yet"},
          authorize?: false,
          tenant: org.id
        )

      assert {:error, %Ash.Error.Invalid{} = error} =
               Federation.rekey_site_federation(bare, authorize?: false, tenant: org.id)

      assert Exception.message(error) =~ "never been enabled"
      assert is_nil(reload(bare, org.id).public_key_pem)
    end
  end

  describe "telling followers" do
    test "re-keying queues exactly one actor Update for the site", ctx do
      Federation.rekey_site_federation!(ctx.settings, authorize?: false, tenant: ctx.org_id)

      assert [_job] = all_enqueued(worker: ActorUpdateWorker, args: %{"org_id" => ctx.org_id})
    end

    test "the Update carries the new key and is signed with it, not the old one", ctx do
      old_public = ctx.settings.public_key_pem

      rekeyed =
        Federation.rekey_site_federation!(ctx.settings, authorize?: false, tenant: ctx.org_id)

      assert :ok = perform_job(ActorUpdateWorker, %{"org_id" => ctx.org_id})

      assert [delivery] =
               Ash.read!(Delivery, authorize?: false, tenant: ctx.org_id)
               |> Enum.filter(&(&1.follower_id == ctx.follower.id))

      assert delivery.activity_type == :update
      assert delivery.document_id == nil
      assert delivery.activity["type"] == "Update"
      assert delivery.activity["actor"] == "https://kiln.example/actor"
      assert delivery.activity["object"]["id"] == "https://kiln.example/actor"
      # The key an `Update`-processing peer swaps in.
      assert delivery.activity["object"]["publicKey"]["publicKeyPem"] == rekeyed.public_key_pem

      assert delivery.activity["object"]["publicKey"]["id"] ==
               "https://kiln.example/actor#main-key"

      test_pid = self()

      Req.Test.stub(KilnCMS.Federation, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:delivered, conn.request_path, conn.req_headers, body})
        Plug.Conn.send_resp(conn, 202, "")
      end)

      assert :ok =
               DeliveryWorker.perform(%Oban.Job{
                 args: %{"org_id" => ctx.org_id, "delivery_id" => delivery.id},
                 attempt: 1,
                 max_attempts: 12
               })

      assert_received {:delivered, path, headers, body}
      assert Jason.decode!(body)["type"] == "Update"

      assert :ok =
               HttpSignature.verify("post", path, headers, body, rekeyed.public_key_pem,
                 host: "remote.example"
               )

      assert {:error, "signature does not verify"} =
               HttpSignature.verify("post", path, headers, body, old_public,
                 host: "remote.example"
               )
    end

    test "a site switched off re-keys but tells nobody", ctx do
      settings =
        Federation.disable_site_federation!(ctx.settings, authorize?: false, tenant: ctx.org_id)

      Federation.rekey_site_federation!(settings, authorize?: false, tenant: ctx.org_id)

      assert :ok = perform_job(ActorUpdateWorker, %{"org_id" => ctx.org_id})
      assert Ash.read!(Delivery, authorize?: false, tenant: ctx.org_id) == []
    end
  end
end
