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

  test "a later publish cannot re-bless doctored history" do
    actor = admin()
    page = published_page(actor)
    assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

    KilnCMS.Repo.update_all(
      from(v in "pages_versions",
        where: v.version_source_id == type(^page.id, :binary_id),
        where: v.version_action_name == "create"
      ),
      set: [changes: %{"title" => "Doctored"}]
    )

    assert {:tampered, _} = Chain.verify(Page, "page", page.id, page.org_id)

    # Publishing again mints a fresh, correctly-signed anchor. If that anchor
    # were re-folded from the LIVE rows it would match the doctored history and
    # verify clean — laundering the tampering, since verify/4 reads the latest
    # anchor. Seeding from the previous anchor's recorded hash prevents it.
    page = KilnCMS.CMS.unpublish_page!(page, %{}, actor: actor)
    page = KilnCMS.CMS.publish_page!(page, %{}, actor: actor)

    assert {:tampered, _} = Chain.verify(Page, "page", page.id, page.org_id)
  end

  test "an incremental anchor agrees with a from-genesis fold on intact history" do
    actor = admin()
    page = published_page(actor)

    page = KilnCMS.CMS.update_page!(page, %{title: "Second"}, actor: actor)
    page = KilnCMS.CMS.unpublish_page!(page, %{}, actor: actor)
    page = KilnCMS.CMS.publish_page!(page, %{}, actor: actor)

    anchor = Chain.latest_anchor("page", page.id, page.org_id)

    # verify/4 recomputes from genesis; the anchor was folded incrementally.
    # They must coincide, or every existing anchor would start reading tampered.
    assert Chain.compute(Page, page.id, page.org_id, anchor.version_count).chain_hash ==
             anchor.chain_hash

    assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
  end

  describe "anchor_every_write" do
    setup do
      Application.put_env(:kiln_cms, :audit_anchor_every_write, true)
      on_exit(fn -> Application.delete_env(:kiln_cms, :audit_anchor_every_write) end)
      :ok
    end

    test "a plain draft edit is anchored, leaving no unanchored tail" do
      actor = admin()

      page =
        CMS.create_page!(
          %{title: "Draft", slug: "chain-w-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      # Never published — under publish-only anchoring this would be
      # :unanchored, the window #356 asks about.
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      page = CMS.update_page!(page, %{title: "Edited"}, actor: actor)

      anchor = Chain.latest_anchor("page", page.id, page.org_id)
      versions = Chain.compute(Page, page.id, page.org_id)
      assert anchor.version_count == versions.version_count
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "the publish anchor still carries published_version_id" do
      actor = admin()
      page = published_page(actor)

      # `:set_published_version_id` runs inside the publish pipeline's
      # after_transaction. Anchoring it would swallow the publish's own version
      # and leave RecordPublishedVersion nothing to anchor, silently dropping
      # the #338 linkage — the publish-time anchor must still carry it.
      anchor = Chain.latest_anchor("page", page.id, page.org_id)
      assert anchor.published_version_id
      assert anchor.published_version_id == page.published_version_id
    end

    test "tampering with a write-anchored draft is still detected" do
      actor = admin()

      page =
        CMS.create_page!(
          %{title: "Draft", slug: "chain-w-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      CMS.update_page!(page, %{title: "Edited"}, actor: actor)

      KilnCMS.Repo.update_all(
        from(v in "pages_versions",
          where: v.version_source_id == type(^page.id, :binary_id),
          where: v.version_action_name == "create"
        ),
        set: [changes: %{"title" => "Doctored"}]
      )

      assert {:tampered, _} = Chain.verify(Page, "page", page.id, page.org_id)
    end
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

  describe "anchor-to-anchor chaining (#597)" do
    test "each anchor after the first names and digests its predecessor" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      [newest, oldest] = Chain.anchors("page", page.id, page.org_id) |> Enum.take(2)

      assert is_nil(oldest.prev_anchor_id)
      assert newest.prev_anchor_id == oldest.id
      assert newest.prev_anchor_digest == Chain.anchor_digest(oldest)

      # That last line alone is a tautology — it recomputes the stored value with
      # the function that produced it, so it holds for any definition, including
      # one that ignores every field. Pin the binding instead.
      for {field, altered} <- [
            {:chain_hash, "doctored"},
            {:signature, "doctored"},
            {:version_count, oldest.version_count + 1}
          ] do
        refute Chain.anchor_digest(Map.put(oldest, field, altered)) ==
                 newest.prev_anchor_digest,
               "anchor_digest/1 ignores #{field}"
      end
    end

    # The laundering route #597 describes: doctor a version, delete the anchors
    # that expose it, wait for the next write, and the fresh anchor is folded
    # from genesis over the doctored rows and verifies clean. Deleting only the
    # OLDER anchors now leaves the newest one pointing at nothing.
    test "deleting a predecessor anchor is detected" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      [newest | older] = Chain.anchors("page", page.id, page.org_id)
      assert older != [], "expected more than one anchor"

      ids = Enum.map(older, & &1.id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id in ^Enum.map(ids, &Ecto.UUID.dump!/1))
      )

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "anchor chain broken"
      assert reason =~ newest.prev_anchor_id
    end

    # A predecessor that is present but rewritten — the other half of the hole.
    test "rewriting a predecessor anchor is detected" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      [_newest | [older | _]] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.update_all(
        from(a in "history_anchors",
          where: a.id == type(^older.id, :binary_id),
          update: [set: [chain_hash: "doctored"]]
        ),
        []
      )

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "anchor chain broken"
    end

    # Stripping the link from a signed anchor is caught by the SIGNATURE, not by
    # `chain_intact/1` — which is the whole reason the columns live inside the
    # signed payload. Without this test, moving them out would silently reopen it.
    test "nulling the link columns on a signed anchor is detected" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      [newest | _] = Chain.anchors("page", page.id, page.org_id)
      refute is_nil(newest.prev_anchor_id)

      KilnCMS.Repo.update_all(
        from(a in "history_anchors",
          where: a.id == type(^newest.id, :binary_id),
          update: [set: [prev_anchor_id: nil, prev_anchor_digest: nil]]
        ),
        []
      )

      assert {:tampered, _} = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # The route #597 filed, which this change narrows but does NOT close. An
    # attacker deletes only the anchors covering the doctored version — the
    # newest, which nothing points at — so `chain_intact/1` sees no dangling
    # link. Characterised rather than asserted-as-correct: when the truncation
    # case is closed this test should FAIL, which is the point of writing it.
    test "deleting the NEWEST anchor is not detected — the open half of #597" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      # The surviving prefix still verifies, so nothing flags the truncation.
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # The residual the moduledoc now states outright: wiping EVERY anchor returns
    # the document to :unanchored rather than being detected as tampering.
    # Asserted so the limit is recorded rather than assumed.
    test "wiping every anchor reads as unanchored, not tampered" do
      page = published_page(admin())
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.source_id == type(^page.id, :binary_id))
      )

      assert :unanchored = Chain.verify(Page, "page", page.id, page.org_id)
    end
  end
end
