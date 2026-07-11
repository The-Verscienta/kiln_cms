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
    access = Keyword.get(opts, :access, :read)
    Accounts.mint_api_key!(owner.id, "CI reader", expires_at, %{access: access}, actor: actor)
  end

  # An actor shaped like the API-key sign-in produces one: the owning user with
  # the matched key record stamped into metadata (see SignInPreparation).
  defp key_actor(owner, key),
    do: Ash.Resource.set_metadata(owner, %{using_api_key?: true, api_key: key})

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
    test "an API-key actor without a key record fails closed, even as an admin" do
      admin = user(:admin)
      # An actor carrying only the marker, no key record — must fail closed.
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

    test "a :read key cannot create content, even on an admin account" do
      admin = user(:admin)
      actor = key_actor(admin, mint(admin, admin))

      assert {:error, %Ash.Error.Forbidden{}} =
               KilnCMS.CMS.create_page(
                 %{title: "Nope", slug: "ro-#{System.unique_integer([:positive])}"},
                 actor: actor
               )
    end

    test "a :read key cannot write taxonomy, even on an admin account" do
      admin = user(:admin)
      actor = key_actor(admin, mint(admin, admin))

      assert {:error, %Ash.Error.Forbidden{}} =
               KilnCMS.CMS.create_tag(
                 %{name: "Nope", slug: "ro-tag-#{System.unique_integer([:positive])}"},
                 actor: actor
               )
    end
  end

  describe "write scope (:read_write keys)" do
    test "keys default to read-only" do
      admin = user(:admin)
      assert mint(user(:editor), admin).access == :read
    end

    test "a write key on an editor account can author drafts but not publish" do
      admin = user(:admin)
      editor = user(:editor)
      actor = key_actor(editor, mint(editor, admin, access: :read_write))

      assert {:ok, page} =
               KilnCMS.CMS.create_page(
                 %{title: "Drafted by LLM", slug: "llm-#{System.unique_integer([:positive])}"},
                 actor: actor
               )

      assert page.state == :draft

      assert {:ok, page} =
               KilnCMS.CMS.update_page(page, %{title: "Drafted, then edited"}, actor: actor)

      assert {:ok, page} = KilnCMS.CMS.submit_page_for_review(page, actor: actor)
      assert page.state == :in_review

      # Publishing is an admin approval step — the editor's key can't skip it.
      assert {:error, %Ash.Error.Forbidden{}} = KilnCMS.CMS.publish_page(page, actor: actor)
    end

    test "a write key inherits its owner's role — a viewer account still cannot author" do
      admin = user(:admin)
      viewer = user(:viewer)
      actor = key_actor(viewer, mint(viewer, admin, access: :read_write))

      assert {:error, %Ash.Error.Forbidden{}} =
               KilnCMS.CMS.create_page(
                 %{title: "Nope", slug: "viewer-#{System.unique_integer([:positive])}"},
                 actor: actor
               )
    end

    test "no key may hard-delete content, even a write key on an admin account" do
      admin = user(:admin)

      page =
        KilnCMS.CMS.create_page!(
          %{title: "Keep", slug: "keep-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      actor = key_actor(admin, mint(admin, admin, access: :read_write))

      assert {:error, %Ash.Error.Forbidden{}} = KilnCMS.CMS.destroy_page(page, actor: actor)

      # The same admin, keyless, may (soft-)delete.
      assert :ok = KilnCMS.CMS.destroy_page(page, actor: admin)
    end
  end
end
