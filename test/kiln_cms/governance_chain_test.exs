defmodule KilnCMS.Governance.ChainTest do
  @moduledoc """
  Tamper-evident history anchors (#356): minted signed on publish, and
  verification detects altered / deleted anchored versions.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.Governance.Chain

  # A real signing key so anchors are signed (the provenance key source).
  setup do
    pem = KilnCMS.Keys.generate_rsa_pem()
    var = "KILN_TEST_ANCHOR_#{System.unique_integer([:positive])}"
    System.put_env(var, pem)
    prev = Application.get_env(:kiln_cms, KilnCMS.Provenance)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Provenance,
      Keyword.merge(prev || [], signing_key: {:env, %{"var" => var}})
    )

    on_exit(fn ->
      if prev, do: Application.put_env(:kiln_cms, KilnCMS.Provenance, prev)
      System.delete_env(var)
    end)

    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "chain-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page(actor) do
    page =
      CMS.create_page!(
        %{title: "Anchored", slug: "chain-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.publish_page!(page, %{}, actor: actor)
  end

  test "publishing mints a signed anchor and the chain verifies" do
    page = published_page(admin())

    anchor = Chain.latest_anchor("page", page.id, page.org_id)
    assert anchor
    assert anchor.version_count >= 1
    assert is_binary(anchor.signature)
    assert is_binary(anchor.key_id)

    assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
  end

  test "edits after the anchor don't break verification (unanchored tail)" do
    actor = admin()
    page = published_page(actor)

    CMS.update_page!(page, %{title: "Edited after anchor"}, actor: actor)

    assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
  end

  test "altering an anchored version row is detected" do
    page = published_page(admin())
    assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

    # Doctor the stored history behind Ash's back, as an attacker with DB
    # access (but no signing key) would.
    {altered, _} =
      KilnCMS.Repo.update_all(
        from(v in "pages_versions",
          where: v.version_source_id == type(^page.id, :binary_id),
          update: [set: [changes: type(^%{"title" => "History was always this"}, :map)]]
        ),
        []
      )

    assert altered >= 1

    assert {:tampered, _reason} = Chain.verify(Page, "page", page.id, page.org_id)
  end

  test "deleting an anchored version row is detected" do
    page = published_page(admin())

    {deleted, _} =
      KilnCMS.Repo.delete_all(
        from(v in "pages_versions", where: v.version_source_id == type(^page.id, :binary_id))
      )

    assert deleted >= 1

    assert {:tampered, "anchored versions are missing"} =
             Chain.verify(Page, "page", page.id, page.org_id)
  end

  test "without a signing key the anchor is stored unsigned but still checks integrity" do
    prev = Application.get_env(:kiln_cms, KilnCMS.Provenance)
    Application.put_env(:kiln_cms, KilnCMS.Provenance, Keyword.delete(prev || [], :signing_key))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Provenance, prev) end)

    page = published_page(admin())

    anchor = Chain.latest_anchor("page", page.id, page.org_id)
    assert is_nil(anchor.signature)
    assert :unsigned = Chain.verify(Page, "page", page.id, page.org_id)
  end

  # Swap in a freshly generated signing key. Returns the PUBLIC half of the key
  # that just got rotated out — what an operator would publish as a retired key.
  defp rotate! do
    prev = Application.get_env(:kiln_cms, KilnCMS.Provenance)
    {:env, %{"var" => var}} = Keyword.fetch!(prev, :signing_key)
    {:ok, outgoing} = KilnCMS.Keys.rsa_private_key(System.get_env(var))

    rotated_var = "KILN_TEST_ROTATED_#{System.unique_integer([:positive])}"
    System.put_env(rotated_var, KilnCMS.Keys.generate_rsa_pem())

    Application.put_env(
      :kiln_cms,
      KilnCMS.Provenance,
      Keyword.merge(prev, signing_key: {:env, %{"var" => rotated_var}}, retired_keys: [])
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Provenance, prev)
      System.delete_env(rotated_var)
    end)

    KilnCMS.Keys.rsa_public_key_pem(outgoing)
  end

  defp register_retired!(entries) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Provenance,
      Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Provenance), retired_keys: entries)
    )
  end

  test "rotating the signing key yields :unverifiable, never a false TAMPERED" do
    page = published_page(admin())
    assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

    # Rotate with the old key registered nowhere: the anchor's signature can't
    # be checked, but intact history must not read as tampering.
    rotate!()

    assert :unverifiable = Chain.verify(Page, "page", page.id, page.org_id)
  end

  test "a retired key registered by its PUBLIC half keeps old anchors :verified" do
    page = published_page(admin())
    assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

    # Rotate, but publish the retired key's public half — the private half can
    # be destroyed and the historical trail still attests.
    public_pem = rotate!()
    refute public_pem =~ "PRIVATE"
    register_retired!([public_pem])

    assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
  end

  test "holding the retired key does not launder a doctored anchor signature" do
    page = published_page(admin())
    register_retired!([rotate!()])

    # The key_id still resolves (via the retired registry), so a signature that
    # fails against it is real evidence — it must read TAMPERED, not the
    # can't-check :unverifiable.
    anchor = Chain.latest_anchor("page", page.id, page.org_id)
    <<first, rest::binary>> = Base.decode64!(anchor.signature)
    forged = <<Bitwise.bxor(first, 0xFF), rest::binary>>

    KilnCMS.Repo.update_all(
      from(a in "history_anchors", where: a.id == type(^anchor.id, :binary_id)),
      set: [signature: Base.encode64(forged)]
    )

    assert {:tampered, "anchor signature does not verify"} =
             Chain.verify(Page, "page", page.id, page.org_id)
  end

  test "an unresolvable retired-key entry is skipped, not fatal" do
    page = published_page(admin())
    public_pem = rotate!()

    # The good entry still resolves despite the broken one ahead of it.
    register_retired!([{:file, %{"path" => "/nonexistent/kiln-retired.pem"}}, public_pem])

    assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
  end

  test "an unpublished draft is simply unanchored" do
    draft =
      CMS.create_page!(
        %{title: "Draft", slug: "chain-d-#{System.unique_integer([:positive])}"},
        actor: admin()
      )

    assert :unanchored = Chain.verify(Page, "page", draft.id, draft.org_id)
  end

  test "the kill switch disables anchoring" do
    Application.put_env(:kiln_cms, :audit_anchors_enabled, false)
    on_exit(fn -> Application.delete_env(:kiln_cms, :audit_anchors_enabled) end)

    page = published_page(admin())
    assert is_nil(Chain.latest_anchor("page", page.id, page.org_id))
  end

  test "the governance trail carries the chain verdict and old → new diffs" do
    actor = admin()
    page = published_page(actor)
    CMS.update_page!(page, %{title: "Renamed"}, actor: actor)

    trail = KilnCMS.Governance.trail("page", page.id, page.org_id)
    assert trail.chain == :verified

    rename =
      Enum.find(
        trail.timeline,
        &(&1.action == :update and Enum.any?(&1.diffs, fn {f, _} -> f == "title" end))
      )

    assert {"title", {"Anchored", "Renamed"}} in rename.diffs
  end
end
