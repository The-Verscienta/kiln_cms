defmodule KilnCMS.Accounts.ApiKeyTest do
  @moduledoc "API-key minting, hashing, expiry and revocation."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKey

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "key-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner, actor, opts \\ []) do
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 30, :day))
    Accounts.mint_api_key!(owner.id, "CI reader", expires_at, actor: actor)
  end

  describe "minting" do
    test "returns the plaintext once and stores only the hash" do
      admin = user(:admin)
      key = mint(user(:viewer), admin)

      plaintext = Ash.Resource.get_metadata(key, :plaintext_api_key)
      assert is_binary(plaintext)
      assert String.starts_with?(plaintext, ApiKey.prefix() <> "_")

      # The stored hash is the SHA-256 of the key material, never the plaintext.
      assert is_binary(key.api_key_hash)
      refute key.api_key_hash == plaintext
    end

    test "is admin-only" do
      viewer = user(:viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.mint_api_key(
                 viewer.id,
                 "nope",
                 DateTime.add(DateTime.utc_now(), 1, :day),
                 actor: viewer
               )
    end
  end

  describe "validity" do
    test "a fresh key is valid and reachable through the owner's valid_api_keys" do
      admin = user(:admin)
      owner = user(:viewer)
      key = mint(owner, admin)

      loaded = Ash.load!(key, [:valid], actor: admin)
      assert loaded.valid

      owner = Ash.load!(owner, [:valid_api_keys], actor: admin)
      assert Enum.map(owner.valid_api_keys, & &1.id) == [key.id]
    end

    test "an expired key is not valid and drops out of valid_api_keys" do
      admin = user(:admin)
      owner = user(:viewer)
      key = mint(owner, admin, expires_at: DateTime.add(DateTime.utc_now(), -1, :minute))

      assert Ash.load!(key, [:valid], actor: admin).valid == false

      owner = Ash.load!(owner, [:valid_api_keys], actor: admin)
      assert owner.valid_api_keys == []
    end

    test "revoking makes a key invalid immediately" do
      admin = user(:admin)
      owner = user(:viewer)
      key = mint(owner, admin)

      revoked = Accounts.revoke_api_key!(key, actor: admin)
      assert revoked.revoked_at

      assert Ash.load!(revoked, [:valid], actor: admin).valid == false

      owner = Ash.load!(owner, [:valid_api_keys], actor: admin)
      assert owner.valid_api_keys == []
    end
  end

  describe "read-only enforcement (defense-in-depth)" do
    test "an API-key actor cannot create content, even as an admin" do
      admin = user(:admin)
      # An actor carrying the api-key metadata the content policy checks.
      api_key_actor = Ash.Resource.set_metadata(admin, %{using_api_key?: true})

      assert {:error, %Ash.Error.Forbidden{}} =
               KilnCMS.CMS.create_page(
                 %{title: "Nope", slug: "ro-#{System.unique_integer([:positive])}"},
                 actor: api_key_actor
               )

      # The same admin, without the api-key marker, can create normally.
      assert {:ok, _page} =
               KilnCMS.CMS.create_page(
                 %{title: "Yes", slug: "rw-#{System.unique_integer([:positive])}"},
                 actor: admin
               )
    end
  end
end
