defmodule KilnCMS.Federation.SystemActorAuthorizationTest do
  @moduledoc """
  What federation's own bookkeeping is *authorized* to do, now that the inbox,
  the fan-out, the delivery worker, the replay-nonce store and
  `mix kiln.federation` run as `%KilnCMS.SystemActor{}` instead of
  `authorize?: false` (#1659).

  The shape of each grant is the point, so every resource has a negative next
  to its positive: the system keeps the follower list and the delivery ledger
  but cannot prune the ledger; it reads the block list but cannot write it; it
  reads and stamps the site's settings but cannot edit them through the form;
  it records and sweeps nonces but cannot list them. Removing any
  `KilnCMS.Checks.SystemActor` clause from these resources must turn a test
  here red.

  Reads assert on the ROW, never on `{:ok, _}`: a refused read under a filter
  policy comes back `{:ok, []}`, so a shape-only assertion would pass with the
  grant removed — and here two of those reads fail OPEN (the inbox's follower
  ceiling counts zero, the nonce check accepts a replay).
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Federation
  alias KilnCMS.Federation.Follower
  alias KilnCMS.Federation.SeenSignature
  alias KilnCMS.Federation.SeenSignatureSweeper
  alias KilnCMS.FederationFixtures
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: KilnCMS.Accounts.default_org_id()
  defp system, do: Federation.system()

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fsa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp actor_uri, do: "https://remote-#{uniq()}.example/users/alice"

  defp follower!(opts \\ []) do
    uri = Keyword.get(opts, :uri, actor_uri())
    tenant = Keyword.get(opts, :tenant, org_id())

    Federation.follow!(uri, uri <> "/inbox", %{}, authorize?: false, tenant: tenant)
  end

  defp delivery!(follower) do
    Federation.create_federation_delivery!(
      %{
        follower_id: follower.id,
        inbox_uri: Follower.delivery_inbox(follower),
        activity_type: :create,
        activity: %{"type" => "Create"}
      },
      authorize?: false,
      tenant: org_id()
    )
  end

  test "Federation.system/0 is a system actor labelled :federation" do
    assert %SystemActor{subsystem: :federation} = Federation.system()
  end

  describe "Follower — the whole list, one org at a time" do
    test "the inbox records a follow and the fan-out reads it back" do
      uri = actor_uri()

      assert {:ok, %{actor_uri: ^uri} = follower} =
               Federation.follow(uri, uri <> "/inbox", %{}, actor: system(), tenant: org_id())

      assert follower.id in ids(Federation.list_followers!(actor: system(), tenant: org_id()))

      assert follower.id in ids(
               Federation.deliverable_followers!(actor: system(), tenant: org_id())
             )
    end

    test "the delivery worker keeps the failure count and drops a dead follower" do
      follower = follower!()

      assert {:ok, %{consecutive_failures: 1} = failed} =
               Federation.record_follower_failure(follower, actor: system(), tenant: org_id())

      assert {:ok, %{consecutive_failures: 0}} =
               Federation.record_follower_success(failed, actor: system(), tenant: org_id())

      assert {:ok, %{id: id}} =
               Federation.get_follower(follower.id, actor: system(), tenant: org_id())

      assert id == follower.id

      assert :ok = Federation.destroy_follower(follower, actor: system(), tenant: org_id())
      refute follower.id in ids(Federation.list_followers!(authorize?: false, tenant: org_id()))
    end

    test "the tenant filter still applies: another org's followers are not in the read" do
      other = KilnCMS.OrgFixtures.org("fsa")
      theirs = follower!(tenant: other.id)
      ours = follower!()

      read = ids(Federation.list_followers!(actor: system(), tenant: org_id()))
      assert ours.id in read
      refute theirs.id in read
    end
  end

  describe "Delivery — write and settle the ledger, never prune it" do
    test "the fan-out writes a row and the worker re-reads and settles it" do
      follower = follower!()

      assert {:ok, delivery} =
               Federation.create_federation_delivery(
                 %{
                   follower_id: follower.id,
                   inbox_uri: Follower.delivery_inbox(follower),
                   activity_type: :accept,
                   activity: %{"type" => "Accept"}
                 },
                 actor: system(),
                 tenant: org_id()
               )

      assert {:ok, %{id: id}} =
               Federation.get_federation_delivery(delivery.id, actor: system(), tenant: org_id())

      assert id == delivery.id

      assert {:ok, %{state: :delivered}} =
               Federation.settle_federation_delivery(
                 delivery,
                 %{state: :delivered, attempts: 1, last_status: 202},
                 actor: system(),
                 tenant: org_id()
               )
    end

    test "it cannot destroy a ledger row" do
      delivery = delivery!(follower!())

      assert {:error, %Ash.Error.Forbidden{}} =
               delivery
               |> Ash.Changeset.for_destroy(:destroy, %{}, actor: system(), tenant: org_id())
               |> Ash.destroy()
    end
  end

  describe "Block — read, and only read" do
    test "the inbox sees an actor block and an instance block" do
      blocked = actor_uri()
      admin = user(:admin)

      Federation.block!(%{kind: :actor, value: blocked, reason: nil},
        actor: admin,
        tenant: org_id()
      )

      Federation.block!(%{kind: :instance, value: "bad.example", reason: nil},
        actor: admin,
        tenant: org_id()
      )

      assert Federation.blocked?(blocked, org_id())
      assert Federation.blocked?("https://bad.example/users/x", org_id())
      refute Federation.blocked?(actor_uri(), org_id())

      values =
        [actor: system(), tenant: org_id()]
        |> Federation.list_blocks!()
        |> Enum.map(& &1.value)

      assert blocked in values
    end

    test "it cannot block or unblock" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Federation.block(%{kind: :instance, value: "nope.example"},
                 actor: system(),
                 tenant: org_id()
               )

      block =
        Federation.block!(%{kind: :instance, value: "kept-#{uniq()}.example"},
          actor: user(:admin),
          tenant: org_id()
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Federation.unblock(block, actor: system(), tenant: org_id())
    end
  end

  describe "SiteFederation — read, stamp and the operator's switches; not the form" do
    setup do
      FederationFixtures.enable_deployment!()
      :ok
    end

    test "every federation path starts from the site's settings" do
      settings = FederationFixtures.enable_site!(org_id())

      assert {:ok, %{id: id}} = Federation.active_settings(org_id())
      assert id == settings.id
    end

    test "the delivery worker stamps the site's last delivery" do
      settings = FederationFixtures.enable_site!(org_id())

      assert {:ok, %{last_delivered_at: %DateTime{}}} =
               Federation.record_site_delivery(settings, actor: system(), tenant: org_id())
    end

    test "the operator enables, re-keys and disables" do
      operator = KilnCMS.SystemActor.new(:operator)

      assert {:ok, settings} =
               Federation.enable_site_federation("https://kiln.example", "kiln",
                 actor: operator,
                 tenant: org_id()
               )

      assert {:ok, rekeyed} =
               Federation.rekey_site_federation(settings, actor: operator, tenant: org_id())

      refute rekeyed.public_key_pem == settings.public_key_pem

      assert {:ok, %{enabled: false}} =
               Federation.disable_site_federation(rekeyed, actor: operator, tenant: org_id())
    end

    # `mix kiln.federation` is the operator's (#1747): the federation paths
    # read and stamp the row, and may not switch federation or rotate its key.
    test "the federation paths' own actor may not enable, re-key or disable" do
      settings = FederationFixtures.enable_site!(org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               Federation.rekey_site_federation(settings, actor: system(), tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               Federation.disable_site_federation(settings, actor: system(), tenant: org_id())
    end

    test "it cannot edit the site's identity through the settings form" do
      FederationFixtures.enable_site!(org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               Federation.save_site_federation(%{display_name: "Hijacked"},
                 actor: system(),
                 tenant: org_id()
               )
    end

    test "the grant is the system actor's alone: an editor still cannot re-key" do
      settings = FederationFixtures.enable_site!(org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               Federation.rekey_site_federation(settings,
                 actor: user(:editor),
                 tenant: org_id()
               )
    end
  end

  describe "SeenSignature — record and sweep, never list" do
    defp hash, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    test "a verified signature is recorded, and the second arrival is the replay" do
      attrs = %{signature_hash: hash(), expires_at: DateTime.add(DateTime.utc_now(), 600)}

      assert {:ok, _row} = Federation.record_seen_signature(attrs, actor: system())

      assert {:error, %Ash.Error.Invalid{}} =
               Federation.record_seen_signature(attrs, actor: system())
    end

    test "the sweeper counts and deletes the expired rows" do
      expired = hash()

      Ash.Seed.seed!(SeenSignature, %{
        signature_hash: expired,
        expires_at: DateTime.add(DateTime.utc_now(), -60)
      })

      assert SeenSignatureSweeper.run() >= 1
      assert SeenSignatureSweeper.run() == 0
    end

    test "nothing lists the table through the plain read, the system actor included" do
      kept = hash()

      Federation.record_seen_signature!(%{signature_hash: kept, expires_at: DateTime.utc_now()},
        actor: system()
      )

      case Ash.read(SeenSignature, actor: system()) do
        {:ok, rows} -> refute Enum.any?(rows, &(&1.signature_hash == kept))
        {:error, error} -> assert %Ash.Error.Forbidden{} = error
      end
    end
  end

  # The two reads whose refusal used to fail OPEN (#1659). Each is exercised
  # with an actor the policy refuses — what a lost grant looks like — and must
  # refuse rather than accept.
  describe "fails closed without the grant" do
    defp signed_headers do
      {:ok, headers} =
        KilnCMS.Federation.HttpSignature.sign(
          "https://kiln.example/actor/inbox",
          "https://remote.example/users/alice#main-key",
          ~s({"type":"Follow"}),
          private_key_pem: KilnCMS.Keys.generate_rsa_pem()
        )

      headers
    end

    test "record_seen: a refused write is :unavailable, not :ok" do
      headers = signed_headers()

      assert {:error, :unavailable} =
               KilnCMS.Federation.HttpSignature.record_seen(headers, actor: nil)

      # And the granted path still records, then spots the replay.
      assert :ok = KilnCMS.Federation.HttpSignature.record_seen(headers)

      assert {:error, "signature replayed"} =
               KilnCMS.Federation.HttpSignature.record_seen(headers)
    end

    test "follower ceiling: a refused count is 'at the ceiling', not 0" do
      follower!()

      assert :ok = KilnCMS.Federation.Inbox.check_follower_ceiling(org_id())

      assert {:error, _reason} =
               KilnCMS.Federation.Inbox.check_follower_ceiling(org_id(), actor: nil)
    end
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)
end
