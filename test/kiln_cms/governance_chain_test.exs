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

    trail = KilnCMS.Governance.trail("page", page.id)
    assert trail.chain == :verified

    rename = Enum.find(trail.timeline, &("title" in &1.changed and &1.action == :update))
    assert {"title", {"Anchored", "Renamed"}} in rename.diffs
  end
end
