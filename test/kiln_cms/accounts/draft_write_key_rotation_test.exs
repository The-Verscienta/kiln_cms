defmodule KilnCMS.Accounts.DraftWriteKeyRotationTest do
  @moduledoc """
  Self-rotation of `:draft_write` keys (ADR 0012, "Rotation"): a key with an
  admin-set rotation window may exchange itself for a fresh key with the same
  owner, scope and name, and nothing else may.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKey
  alias KilnCMS.Accounts.Validations.DraftWriteKey

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rot-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp days(n), do: DateTime.add(DateTime.utc_now(), n, :day)

  defp mint(owner, attrs \\ %{}) do
    attrs = Map.merge(%{access: :draft_write, rotatable_until: days(180)}, attrs)
    expires_at = Map.get(attrs, :expires_at, days(7))

    Accounts.mint_api_key(
      owner.id,
      "svc",
      expires_at,
      Map.delete(attrs, :expires_at),
      actor: user(:admin)
    )
  end

  defp plaintext(key), do: Ash.Resource.get_metadata(key, :plaintext_api_key)

  defp actor_for(key) do
    {:ok, actor} = Accounts.actor_from_api_key(plaintext(key))
    actor
  end

  # An actor carrying `key` as the key it authenticated with, without going
  # through sign-in — for keys sign-in would (rightly) refuse.
  defp actor_carrying(owner, key),
    do: Ash.Resource.set_metadata(owner, %{using_api_key?: true, api_key: key})

  defp collect_sql(acc) do
    receive do
      {:sql, sql} -> collect_sql([sql | acc])
    after
      0 -> acc
    end
  end

  defp reload(key), do: Accounts.get_api_key!(key.id, authorize?: false)

  describe "minting a rotation window" do
    test "a draft-write key may carry one" do
      owner = user(:viewer)
      assert {:ok, key} = mint(owner)
      assert %DateTime{} = key.rotatable_until
    end

    test "is optional, and off by default" do
      assert {:ok, key} = mint(user(:viewer), %{rotatable_until: nil})
      assert is_nil(key.rotatable_until)
    end

    test "is capped at the configured maximum" do
      assert {:error, %Ash.Error.Invalid{} = error} =
               mint(user(:viewer), %{rotatable_until: days(DraftWriteKey.max_rotation_days() + 1)})

      assert Exception.message(error) =~ "rotate for at most"
    end

    test "must end in the future" do
      assert {:error, %Ash.Error.Invalid{}} =
               mint(user(:viewer), %{rotatable_until: days(-1)})
    end

    test "is refused on any other scope" do
      for access <- [:read, :read_write] do
        assert {:error, %Ash.Error.Invalid{} = error} =
                 mint(user(:editor), %{access: access})

        assert Exception.message(error) =~ "only a draft-write key can self-rotate"
      end
    end
  end

  describe "rotating" do
    setup do
      owner = user(:viewer)
      {:ok, key} = mint(owner)
      %{owner: owner, key: key}
    end

    test "issues a fresh key of the same owner, scope and name", %{owner: owner, key: key} do
      assert {:ok, new} = Accounts.rotate_api_key(actor: actor_for(key))

      assert new.id != key.id
      assert new.user_id == owner.id
      assert new.access == :draft_write
      assert new.name == key.name
      assert new.rotatable_until == key.rotatable_until
      assert new.rotated_from_id == key.id
      assert new.lineage_id == key.id
      assert "kiln_" <> _ = plaintext(new)
      assert plaintext(new) != plaintext(key)
    end

    test "revokes the presenting key in the same transaction", %{key: key} do
      assert {:ok, new} = Accounts.rotate_api_key(actor: actor_for(key))

      assert %DateTime{} = reload(key).revoked_at
      assert :error = Accounts.actor_from_api_key(plaintext(key))
      assert {:ok, _} = Accounts.actor_from_api_key(plaintext(new))
    end

    test "the new key lives at most the draft-write lifetime cap", %{key: key} do
      assert {:ok, new} = Accounts.rotate_api_key(actor: actor_for(key))

      limit = days(DraftWriteKey.max_ttl_days())
      assert DateTime.compare(new.expires_at, limit) != :gt
      assert DateTime.diff(limit, new.expires_at, :second) < 60
    end

    test "the new key never outlives the rotation window" do
      owner = user(:viewer)
      until = days(3)
      {:ok, key} = mint(owner, %{rotatable_until: until, expires_at: days(1)})

      assert {:ok, new} = Accounts.rotate_api_key(actor: actor_for(key))
      assert new.expires_at == until
    end

    test "a chain keeps its lineage and its ceiling", %{key: key} do
      {:ok, second} = Accounts.rotate_api_key(actor: actor_for(key))
      {:ok, third} = Accounts.rotate_api_key(actor: actor_for(second))

      assert third.lineage_id == key.id
      assert third.rotated_from_id == second.id
      assert third.rotatable_until == key.rotatable_until

      assert [live] = Accounts.list_live_api_keys_in_lineage!(key.id, authorize?: false)
      assert live.id == third.id
    end

    test "accepts no input: not the scope, the owner, the name or the expiry", %{key: key} do
      actor = actor_for(key)

      for input <- [
            %{access: :read_write},
            %{user_id: user(:editor).id},
            %{name: "other"},
            %{expires_at: days(365)},
            %{rotatable_until: days(365)}
          ] do
        assert {:error, %Ash.Error.Invalid{}} = Accounts.rotate_api_key(input, actor: actor)
      end

      assert is_nil(reload(key).revoked_at)
    end

    test "the same key cannot rotate twice: a lineage has one live key", %{key: key} do
      actor = actor_for(key)
      assert {:ok, _} = Accounts.rotate_api_key(actor: actor)

      # The second call carries the actor struct read before the first rotation,
      # as a concurrent request would. The row lock sees the revocation.
      assert {:error, error} = Accounts.rotate_api_key(actor: actor)
      assert Exception.message(error) =~ "can no longer rotate"

      assert [_one] = Accounts.list_live_api_keys_in_lineage!(key.id, authorize?: false)
    end

    # Two concurrent rotations of one key must serialize, or both could read the
    # row unrevoked and a lineage would fork into two live keys. The SQL sandbox
    # runs a test's transactions one at a time, so the race itself cannot be
    # staged here; what is pinned is that the re-read takes the row lock.
    test "re-reads the presenting key under a row lock", %{key: key} do
      test_pid = self()
      handler = "rotation-lock-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:kiln_cms, :repo, :query],
        fn _event, _measurements, %{query: sql}, _ ->
          if self() == test_pid, do: send(test_pid, {:sql, sql})
        end,
        nil
      )

      try do
        assert {:ok, _} = Accounts.rotate_api_key(actor: actor_for(key))
      after
        :telemetry.detach(handler)
      end

      assert_received {:sql, sql} when is_binary(sql)
      sqls = collect_sql([sql])

      assert Enum.any?(sqls, &(&1 =~ ~s(FROM "api_keys") and &1 =~ "FOR UPDATE")),
             "no locking read of api_keys among: #{inspect(sqls)}"
    end

    test "an owner promoted to editor since the mint stops the lineage", %{
      owner: owner,
      key: key
    } do
      actor = actor_for(key)
      Ash.Seed.update!(owner, %{role: :editor})

      assert {:error, %Ash.Error.Invalid{} = error} = Accounts.rotate_api_key(actor: actor)
      assert Exception.message(error) =~ "cannot edit or publish"
      assert is_nil(reload(key).revoked_at)
    end
  end

  describe "who may not rotate" do
    test "a draft-write key without a rotation window" do
      {:ok, key} = mint(user(:viewer), %{rotatable_until: nil})

      assert {:error, %Ash.Error.Forbidden{}} = Accounts.rotate_api_key(actor: actor_for(key))
      assert is_nil(reload(key).revoked_at)
    end

    test "a revoked key" do
      owner = user(:viewer)
      {:ok, key} = mint(owner)
      actor = actor_for(key)
      {:ok, revoked} = Accounts.revoke_api_key(key, actor: user(:admin))

      # Sign-in refuses it outright…
      assert :error = Accounts.actor_from_api_key(plaintext(key))

      # …and an actor that authenticated before the revocation is refused by
      # the policy (revoked struct) and by the row lock (stale struct).
      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.rotate_api_key(actor: actor_carrying(owner, revoked))

      assert {:error, _} = Accounts.rotate_api_key(actor: actor)
      assert [] = Accounts.list_live_api_keys_in_lineage!(key.id, authorize?: false)
    end

    test "an expired key" do
      owner = user(:viewer)
      {:ok, key} = mint(owner)
      expired = %{key | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.rotate_api_key(actor: actor_carrying(owner, expired))
    end

    test "a key whose rotation window has closed" do
      owner = user(:viewer)
      {:ok, key} = mint(owner)
      closed = %{key | rotatable_until: DateTime.add(DateTime.utc_now(), -1, :second)}

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.rotate_api_key(actor: actor_carrying(owner, closed))
    end

    test "a read or read-write key, even with a forged window" do
      for {role, access} <- [{:viewer, :read}, {:editor, :read_write}] do
        owner = user(role)

        {:ok, key} =
          Accounts.mint_api_key(owner.id, "k", days(7), %{access: access}, actor: user(:admin))

        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.rotate_api_key(actor: actor_for(key))

        forged = %{key | rotatable_until: days(30)}

        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.rotate_api_key(actor: actor_carrying(owner, forged))
      end
    end

    test "an actor that is not a key, admins included" do
      for actor <- [user(:admin), user(:editor), user(:viewer), nil] do
        assert {:error, %Ash.Error.Forbidden{}} = Accounts.rotate_api_key(actor: actor)
      end
    end

    test "a user struct merely claiming a key it did not authenticate with" do
      owner = user(:viewer)
      {:ok, key} = mint(owner)
      claimed = Ash.Resource.set_metadata(owner, %{api_key: key})

      assert {:error, %Ash.Error.Forbidden{}} = Accounts.rotate_api_key(actor: claimed)
    end
  end

  test "admins still manage keys: rotation's policy did not displace theirs" do
    admin = user(:admin)
    {:ok, key} = mint(user(:viewer))

    assert {:ok, _} = Accounts.get_api_key(key.id, actor: admin)
    assert {:ok, _} = Accounts.revoke_api_key(key, actor: admin)

    # A key cannot read the key list, its own row included.
    assert {:error, _} = Accounts.get_api_key(key.id, actor: actor_for_viewer_key())
  end

  defp actor_for_viewer_key do
    {:ok, key} = mint(user(:viewer))
    actor_for(key)
  end

  test "ApiKey's rotation lineage relationships load" do
    {:ok, key} = mint(user(:viewer))
    {:ok, new} = Accounts.rotate_api_key(actor: actor_for(key))

    loaded = Ash.load!(reload(key), [:rotated_to], authorize?: false)
    assert %ApiKey{id: id} = loaded.rotated_to
    assert id == new.id
  end
end
