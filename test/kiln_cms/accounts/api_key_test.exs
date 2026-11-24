defmodule KilnCMS.Accounts.ApiKeyTest do
  @moduledoc "API-key minting, hashing, expiry and revocation."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKey
  alias KilnCMS.Accounts.Checks.{ApiKeyWithoutWriteAccess, DraftWriteKey}
  alias KilnCMS.NewerReleaseRows
  alias KilnCMS.Types.UnknownAtom

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

    test "an erased account's unrevoked key is not valid" do
      admin = user(:admin)
      owner = user(:viewer)
      key = mint(owner, admin)
      live = mint(user(:viewer), admin)

      # Erased with the key left unrevoked, as erasure did before it revoked keys.
      Ash.Seed.update!(owner, %{anonymized_at: DateTime.utc_now()})

      assert Ash.load!(key, [:valid], actor: admin).valid == false
      assert Ash.load!(live, [:valid], actor: admin).valid
      assert is_nil(Accounts.get_api_key!(key.id, actor: admin).revoked_at)
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

    test "no key may HARD-delete (:purge) content, even a write key on an admin account" do
      admin = user(:admin)

      page =
        KilnCMS.CMS.create_page!(
          %{title: "Keep", slug: "keep-#{System.unique_integer([:positive])}"},
          actor: admin
        )

      actor = key_actor(admin, mint(admin, admin, access: :read_write))

      # Hard delete stays banned for every key regardless of scope/role (#330).
      assert {:error, %Ash.Error.Forbidden{}} = KilnCMS.CMS.purge_page(page, actor: actor)

      # The same admin, keyless, may hard-delete (a trashed row: #2531).
      :ok = KilnCMS.CMS.destroy_page(page, actor: admin)
      assert :ok = KilnCMS.CMS.purge_page(page, actor: admin)
    end

    test "a write key soft-deletes as its owner's role — admin yes, but a read key never" do
      admin = user(:admin)
      slug = fn -> "sd-#{System.unique_integer([:positive])}" end

      p1 = KilnCMS.CMS.create_page!(%{title: "SD", slug: slug.()}, actor: admin)
      p2 = KilnCMS.CMS.create_page!(%{title: "SD", slug: slug.()}, actor: admin)

      # A read-only key can never soft-delete (fails the write-scope gate).
      read_actor = key_actor(admin, mint(admin, admin))
      assert {:error, %Ash.Error.Forbidden{}} = KilnCMS.CMS.destroy_page(p1, actor: read_actor)

      # A :read_write key acts as its owner — an admin's key may soft-delete (#330).
      write_actor = key_actor(admin, mint(admin, admin, access: :read_write))
      assert :ok = KilnCMS.CMS.destroy_page(p2, actor: write_actor)
    end
  end

  # A key a newer release minted with a scope this one does not know (#2604),
  # met after a rollback or during a rolling deploy.
  describe "a scope this release does not know" do
    setup do
      admin = user(:admin)
      owner = user(:viewer)
      key = mint(owner, admin)
      %{admin: admin, owner: owner, key: key, plaintext: plaintext(key)}
    end

    test "loads as an UnknownAtom from a get and from both lists", ctx do
      NewerReleaseRows.api_key_scope!(ctx.key.id)
      unknown = %UnknownAtom{value: NewerReleaseRows.unknown()}

      assert Accounts.get_api_key!(ctx.key.id, actor: ctx.admin).access == unknown
      assert [%{access: ^unknown}] = Accounts.list_api_keys!(ctx.owner.id, actor: ctx.admin)

      assert %{access: ^unknown} =
               [actor: ctx.admin] |> Accounts.list_all_api_keys!() |> by_id(ctx.key.id)
    end

    # A release older than this one's predecessor read any existing atom as
    # itself: "admin" is an atom every VM holds, and outside `one_of`.
    test "a stored scope naming an existing atom loads as unknown too", ctx do
      NewerReleaseRows.api_key_scope!(ctx.key.id, "admin")

      assert Accounts.get_api_key!(ctx.key.id, actor: ctx.admin).access ==
               %UnknownAtom{value: "admin"}

      assert Accounts.actor_from_api_key(ctx.plaintext) == :error
    end

    test "is not valid and drops out of valid_api_keys", ctx do
      NewerReleaseRows.api_key_scope!(ctx.key.id)

      assert Ash.load!(Accounts.get_api_key!(ctx.key.id, actor: ctx.admin), [:valid],
               actor: ctx.admin
             ).valid == false

      assert Ash.load!(ctx.owner, [:valid_api_keys], actor: ctx.admin).valid_api_keys == []
    end

    test "resolves to no actor, where the same key with a known scope did", ctx do
      assert {:ok, %{id: id}} = Accounts.actor_from_api_key(ctx.plaintext)
      assert id == ctx.owner.id

      NewerReleaseRows.api_key_scope!(ctx.key.id)
      assert Accounts.actor_from_api_key(ctx.plaintext) == :error

      # A release that knows the scope signs it in again.
      NewerReleaseRows.api_key_scope!(ctx.key.id, "read")
      assert {:ok, _actor} = Accounts.actor_from_api_key(ctx.plaintext)
    end

    test "can be revoked, leaving the stored scope as it was", ctx do
      NewerReleaseRows.api_key_scope!(ctx.key.id)
      loaded = Accounts.get_api_key!(ctx.key.id, actor: ctx.admin)

      assert %{revoked_at: %DateTime{}} = Accounts.revoke_api_key!(loaded, actor: ctx.admin)

      row = NewerReleaseRows.stored_row("api_keys", ctx.key.id)
      assert row["access"] == NewerReleaseRows.unknown()
      assert row["revoked_at"]
    end

    # The sign-in filter is the only gate. The content policies do refuse
    # writes, but the drafts-only clamps on reads would not apply.
    test "an actor carrying one is refused writes but not clamped as drafts-only", ctx do
      NewerReleaseRows.api_key_scope!(ctx.key.id)
      loaded = Accounts.get_api_key!(ctx.key.id, actor: ctx.admin)
      actor = key_actor(ctx.admin, loaded)

      assert ApiKeyWithoutWriteAccess.match?(actor, %{}, [])
      refute DraftWriteKey.draft_write?(actor)
    end
  end

  describe "minting a scope" do
    test "this release does not know is refused" do
      admin = user(:admin)

      for access <- [NewerReleaseRows.unknown(), :ok, %UnknownAtom{value: "read"}] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Accounts.mint_api_key(
                   user(:viewer).id,
                   "nope",
                   DateTime.add(DateTime.utc_now(), 1, :day),
                   %{access: access},
                   actor: admin
                 ),
               "minted #{inspect(access)}"
      end
    end
  end

  defp plaintext(key), do: Ash.Resource.get_metadata(key, :plaintext_api_key)

  defp by_id(keys, id), do: Enum.find(keys, &(&1.id == id))
end
