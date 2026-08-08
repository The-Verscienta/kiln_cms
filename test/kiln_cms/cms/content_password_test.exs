defmodule KilnCMS.CMS.ContentPasswordTest do
  @moduledoc """
  The stored side of passphrase-locked content (#496): what a lock actually
  writes, what leaves it alone, and what rotation does to an outstanding grant.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentPassword

  setup do
    %{actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "lock-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp page(actor, attrs) do
    CMS.create_page!(
      Map.merge(%{title: "Locked", slug: "lock-#{System.unique_integer([:positive])}"}, attrs),
      actor: actor
    )
  end

  defp reload(record), do: Ash.reload!(record, authorize?: false, tenant: record.org_id)

  describe "setting a passphrase" do
    test "stores a hash and a fingerprint, never the passphrase", ctx do
      page = page(ctx.actor, %{access_password: "open sesame"})

      assert is_binary(page.access_password_hash)
      refute page.access_password_hash =~ "open sesame"
      assert page.password_fingerprint == ContentPassword.fingerprint(page.access_password_hash)
      assert ContentPassword.verify(page.access_password_hash, "open sesame")
      refute ContentPassword.verify(page.access_password_hash, "not it")
    end

    test "two documents sharing a passphrase get different fingerprints", ctx do
      one = page(ctx.actor, %{access_password: "same words"})
      two = page(ctx.actor, %{access_password: "same words"})

      # bcrypt salts per row, so the fingerprint identifies THIS document's
      # passphrase — which is what lets a grant be document-scoped without
      # carrying a document id.
      refute one.password_fingerprint == two.password_fingerprint
    end

    test "a blank passphrase leaves an existing one alone", ctx do
      page = page(ctx.actor, %{access_password: "keep me"})

      # The trap this exists to prevent: the editor re-submits every field on
      # every save and never echoes the password back, so blank is the normal
      # submission for an unchanged passphrase. Reading it as "clear" would drop
      # the lock off a published document the first time anyone edited its title.
      updated =
        CMS.update_page!(page, %{title: "Retitled", access_password: ""}, actor: ctx.actor)

      assert updated.access_password_hash == page.access_password_hash
      assert updated.password_fingerprint == page.password_fingerprint
    end

    test "an omitted passphrase leaves an existing one alone", ctx do
      page = page(ctx.actor, %{access_password: "keep me"})

      updated = CMS.update_page!(page, %{title: "Retitled"}, actor: ctx.actor)

      assert updated.access_password_hash == page.access_password_hash
    end
  end

  describe "clearing" do
    test "an explicit removal clears both columns", ctx do
      page = page(ctx.actor, %{access_password: "temporary"})

      updated = CMS.update_page!(page, %{remove_access_password: true}, actor: ctx.actor)

      assert is_nil(updated.access_password_hash)
      assert is_nil(updated.password_fingerprint)
    end

    test "removal wins over a passphrase submitted in the same save", ctx do
      page = page(ctx.actor, %{access_password: "old"})

      updated =
        CMS.update_page!(
          page,
          %{access_password: "new", remove_access_password: true},
          actor: ctx.actor
        )

      assert is_nil(updated.access_password_hash)
    end
  end

  describe "rotation" do
    test "changes the fingerprint, which is what invalidates outstanding grants", ctx do
      page = page(ctx.actor, %{access_password: "first"})
      before = page.password_fingerprint

      rotated = CMS.update_page!(page, %{access_password: "second"}, actor: ctx.actor)

      refute rotated.password_fingerprint == before
      assert ContentPassword.verify(rotated.access_password_hash, "second")
      refute ContentPassword.verify(rotated.access_password_hash, "first")
    end
  end

  describe "version history" do
    test "never carries the hash", ctx do
      page = page(ctx.actor, %{access_password: "secret words"})
      CMS.publish_page!(page, actor: ctx.actor)
      CMS.update_page!(reload(page), %{access_password: "rotated words"}, actor: ctx.actor)

      changes =
        KilnCMS.CMS.Page.Version
        |> Ash.Query.filter(version_source_id: page.id)
        |> Ash.read!(authorize?: false, tenant: page.org_id)
        |> Enum.flat_map(&Map.keys(&1.changes || %{}))

      # A bcrypt hash in version history would outlive every rotation and be
      # readable by anyone who can read versions — which is a wider set than
      # the people who know the passphrase.
      refute "access_password_hash" in changes
      refute "password_fingerprint" in changes
    end
  end

  describe "verify/2" do
    test "an unlocked record never matches, whatever is submitted" do
      refute ContentPassword.verify(nil, "anything")
      refute ContentPassword.verify(nil, nil)
    end

    test "a non-binary passphrase is refused rather than crashing" do
      hash = ContentPassword.hash("real")

      refute ContentPassword.verify(hash, nil)
      refute ContentPassword.verify(hash, %{"nested" => "map"})
      refute ContentPassword.verify(hash, ["list"])
    end

    test "hash/1 treats blank as no lock" do
      assert is_nil(ContentPassword.hash(nil))
      assert is_nil(ContentPassword.hash(""))
      assert is_nil(ContentPassword.hash("   "))
    end
  end

  describe "grants" do
    test "round-trip a fingerprint" do
      token = ContentPassword.sign("fingerprint-value")

      assert {:ok, "fingerprint-value"} = ContentPassword.verify_grant(token)
    end

    test "reject anything that isn't one" do
      assert {:error, _} = ContentPassword.verify_grant("not-a-token")
      assert {:error, _} = ContentPassword.verify_grant(nil)
      assert {:error, _} = ContentPassword.verify_grant(%{})
    end
  end
end
