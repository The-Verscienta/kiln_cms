defmodule KilnCMS.Governance.ChainTest do
  @moduledoc """
  Tamper-evident history anchors (#356): minted signed on publish, and
  verification detects altered / deleted anchored versions.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  require Ash.Query
  import ExUnit.CaptureLog

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

  # The debounced editor save, which is what `CoalesceAutosaveVersions` runs on.
  # There is no code interface for it — it is reached only from
  # `ContentEditorLive.do_autosave/1` — so the changeset is built directly.
  defp autosave!(page, title, actor) do
    page
    |> Ash.Changeset.for_update(:autosave, %{title: title}, actor: actor)
    |> Ash.update!()
  end

  # The version rows sorting at or before the anchor's recorded boundary — the
  # ones it folded, and therefore the ones that must never move.
  #
  # The comparison is spelled out rather than borrowed from `Chain`, on purpose:
  # asserting through `anchored_boundary/1` would let a wrong boundary agree
  # with itself. The caller cross-checks the count against the anchor's own
  # `version_count`, which is the value this cannot compute.
  defp anchored_version_ids(page, %{last_version_at: at} = anchor) when not is_nil(at) do
    Page.Version
    |> Ash.Query.filter(version_source_id == ^page.id)
    |> Ash.Query.sort(version_inserted_at: :asc, id: :asc)
    |> Ash.read!(authorize?: false, tenant: page.org_id)
    |> Enum.filter(fn v ->
      case DateTime.compare(v.version_inserted_at, at) do
        :lt -> true
        :eq -> v.id <= anchor.last_version_id
        :gt -> false
      end
    end)
    |> Enum.map(& &1.id)
  end

  defp autosave_count(page) do
    Page.Version
    |> Ash.Query.filter(version_source_id == ^page.id and version_action_name == :autosave)
    |> Ash.count!(authorize?: false, tenant: page.org_id)
  end

  # Every field `Chain`'s item digest folds, so a rewritten `changes` map or a
  # deleted row both show up as a difference.
  defp version_digests(page, ids) do
    Page.Version
    |> Ash.Query.filter(version_source_id == ^page.id and id in ^ids)
    |> Ash.read!(authorize?: false, tenant: page.org_id)
    |> Map.new(&{&1.id, {&1.version_action_name, &1.version_inserted_at, &1.changes}})
  end

  # A version row stamped BEFORE every row an existing anchor already covered —
  # what a concurrent write whose row commits out of stamp order leaves behind,
  # or a second app node whose wall clock runs behind (`version_inserted_at` is
  # stamped by the node doing the writing). Seeded directly because DataCase
  # shares ONE sandboxed connection, so genuinely concurrent transactions are
  # not available to reproduce it — the row it leaves is, and that is what the
  # fold actually sees.
  #
  # `at` defaults before every real row; pass one to place the row elsewhere.
  defp backdated_version!(page, at \\ ~U[2000-01-01 00:00:00.000000Z]) do
    Ash.Seed.seed!(Page.Version, %{
      version_source_id: page.id,
      org_id: page.org_id,
      version_action_type: :update,
      version_action_name: :update,
      version_inserted_at: at,
      version_updated_at: at,
      changes: %{"title" => "Committed late"}
    })
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

    # #671. Two features that are each correct alone and were fatal together:
    # `AnchorVersion` anchors every autosave, and `CoalesceAutosaveVersions`
    # then destroys the superseded rows and rewrites the survivor's `changes` —
    # both of which the anchor already committed to. The verdict was permanently
    # red with no tampering, on the one configuration that exists to make the
    # audit surface stronger, and autosave is on by default in the editor.
    test "autosaving twice does not fake a tamper verdict" do
      actor = admin()
      page = published_page(actor)
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      page = autosave!(page, "First autosave", actor)
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      page = autosave!(page, "Second autosave", actor)
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      # A third, because the run only became coalescible at two: the second
      # save is what first had a predecessor to supersede.
      _page = autosave!(page, "Third autosave", actor)
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "no anchored version row is destroyed or rewritten by coalescing" do
      actor = admin()
      page = published_page(actor)

      page = autosave!(page, "First autosave", actor)
      anchor = Chain.latest_anchor("page", page.id, page.org_id)
      anchored = anchored_version_ids(page, anchor)
      digests = version_digests(page, anchored)

      # Or the comparison below is `%{} == %{}` and holds for the trivial
      # reason that it selected nothing. Cross-checked against a number the
      # helper did not compute: create + publish + the first autosave.
      assert length(anchored) == anchor.version_count
      assert anchor.version_count == 3

      _page = page |> autosave!("Second autosave", actor) |> autosave!("Third", actor)

      # The rows an anchor committed to must still exist, byte-identical in
      # every field the item digest folds. Asserted directly rather than only
      # through the verdict: a future change could make `verify/4` tolerant
      # without making the history honest.
      assert version_digests(page, anchored) == digests
    end

    test "a never-published draft is protected the same way" do
      # The shape the flag actually produces in the editor: `do_autosave/1` is
      # gated on `state == :draft`, so a published page is not what autosave
      # runs against. With no publish there is no non-autosave version to bound
      # the run either, so the anchor is the ONLY thing holding the line.
      actor = admin()

      page =
        CMS.create_page!(
          %{title: "Draft", slug: "chain-d671-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      page = page |> autosave!("One", actor) |> autosave!("Two", actor)

      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
      assert autosave_count(page) == 2
    end

    test "the cost is paid in version rows, not in a wrong verdict" do
      actor = admin()
      page = published_page(actor)

      _page =
        page
        |> autosave!("One", actor)
        |> autosave!("Two", actor)
        |> autosave!("Three", actor)

      # The honest trade, asserted so it is a decision rather than a surprise:
      # when every save is anchored there is never an unanchored pair to
      # collapse, so the run #32 exists to compress stays uncompressed. Off by
      # default, and `docs/editorial-consent.md` states it as the cost of the
      # setting. The alternative — coalescing anyway — is the permanent false
      # tamper verdict above.
      assert autosave_count(page) == 3
    end
  end

  describe "coalescing against an anchored prefix" do
    # These run with `anchor_every_write` OFF, so the boundary can be placed
    # deliberately rather than covering everything. That is the only way to
    # exercise a PARTIAL cut — the case where `after_anchored/2` returns a
    # proper subset of the trailing run, which is where a wrong boundary would
    # either destroy anchored history or silently disable #32.

    test "with anchoring at publish only, the autosave run still collapses" do
      # The default configuration, and the control for everything below: the
      # anchored boundary is the publish's own version, every autosave sorts
      # after it, so #32's coalescing is untouched.
      refute Chain.every_write?()

      actor = admin()
      page = published_page(actor)

      page =
        page
        |> autosave!("One", actor)
        |> autosave!("Two", actor)
        |> autosave!("Three", actor)

      assert autosave_count(page) == 1
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "a boundary inside the run freezes the anchored rows and collapses the rest" do
      actor = admin()
      page = published_page(actor)

      page = autosave!(page, "One", actor)
      :ok = Chain.anchor(page)
      frozen = Chain.latest_anchor("page", page.id, page.org_id)

      page = page |> autosave!("Two", actor) |> autosave!("Three", actor)

      # One anchored autosave, untouched, plus the two later ones merged.
      assert autosave_count(page) == 2
      assert version_digests(page, anchored_version_ids(page, frozen)) != %{}
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      # The merge still carries the whole run's cumulative delta, so a restore
      # of the survivor reconstructs every field — what #32 promises.
      [_anchored, merged] =
        Page.Version
        |> Ash.Query.filter(version_source_id == ^page.id and version_action_name == :autosave)
        |> Ash.Query.sort(version_inserted_at: :asc, id: :asc)
        |> Ash.read!(authorize?: false, tenant: page.org_id)

      assert merged.changes["title"] == "Three"
    end

    test "an anchor that recorded only a count still protects its rows" do
      actor = admin()
      page = published_page(actor)

      page = autosave!(page, "One", actor)
      :ok = Chain.anchor(page)
      anchor = Chain.latest_anchor("page", page.id, page.org_id)
      anchored = anchored_version_ids(page, anchor)
      digests = version_digests(page, anchored)

      # Anchors minted before #598 carry no boundary timestamp, only a
      # `version_count`. `resolved_boundary/2` resolves that to the same sort
      # key by reading the row at that position — the one branch of the fix
      # nothing else exercises.
      KilnCMS.Repo.update_all(
        from(a in "history_anchors", where: a.id == type(^anchor.id, :binary_id)),
        set: [last_version_at: nil, last_version_id: nil]
      )

      _page = page |> autosave!("Two", actor) |> autosave!("Three", actor)

      assert version_digests(page, anchored) == digests
      assert autosave_count(page) == 2
    end

    test "an unresolvable count refuses to coalesce rather than guessing" do
      actor = admin()
      page = published_page(actor)

      page = autosave!(page, "One", actor)
      :ok = Chain.anchor(page)
      anchor = Chain.latest_anchor("page", page.id, page.org_id)

      # A count larger than the surviving rows: the state a document damaged by
      # #671 on a pre-#598 deployment is already in. There is no row to resolve
      # the position to, so the honest answer is "cannot tell" — and the
      # conservative response to that is to touch nothing, not to assume
      # nothing is anchored.
      KilnCMS.Repo.update_all(
        from(a in "history_anchors", where: a.id == type(^anchor.id, :binary_id)),
        set: [last_version_at: nil, last_version_id: nil, version_count: 99]
      )

      assert :unknown = Chain.anchored_boundary(page)

      _page = page |> autosave!("Two", actor) |> autosave!("Three", actor)

      assert autosave_count(page) == 3
    end

    test "the master kill switch does not open the gate on rows already anchored" do
      actor = admin()
      page = published_page(actor)

      page = autosave!(page, "One", actor)
      :ok = Chain.anchor(page)
      anchor = Chain.latest_anchor("page", page.id, page.org_id)
      anchored = anchored_version_ids(page, anchor)
      digests = version_digests(page, anchored)

      # `audit_anchors_enabled: false` stops anchoring; it does not delete the
      # anchors already minted, and they still commit to what they commit to.
      # Reading `[]` here because the feature is "off" would let coalescing eat
      # them and red the document the moment the switch came back on.
      Application.put_env(:kiln_cms, :audit_anchors_enabled, false)
      on_exit(fn -> Application.delete_env(:kiln_cms, :audit_anchors_enabled) end)

      _page = page |> autosave!("Two", actor) |> autosave!("Three", actor)

      Application.delete_env(:kiln_cms, :audit_anchors_enabled)

      assert version_digests(page, anchored) == digests
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
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

  describe "resuming the fold by position (#598)" do
    test "a row that lands below the boundary is not skipped, nor the boundary re-folded" do
      page = published_page(admin())
      before = Chain.latest_anchor("page", page.id, page.org_id)
      assert before.version_count >= 1

      backdated_version!(page)

      # The seeded row has to actually be visible to the chain's own queries, or
      # every assertion below holds for the trivial reason that nothing changed
      # and this stops being a regression test at all.
      assert Chain.compute(Page, page.id, page.org_id).version_count ==
               before.version_count + 1

      capture_log(fn -> :ok = Chain.anchor(page) end)
      now = Chain.latest_anchor("page", page.id, page.org_id)

      # Nothing sorts after the boundary, so the new anchor must cover exactly
      # what the old one did. Resuming by `OFFSET version_count` instead skips
      # the back-dated row — the very row it means to fold — and folds the
      # boundary row a second time, minting a hash over a sequence that never
      # existed and a count one too high.
      refute now.id == before.id
      assert now.version_count == before.version_count
      assert now.chain_hash == before.chain_hash
      assert now.last_version_id == before.last_version_id
      assert now.last_version_at == before.last_version_at
    end

    test "a row appended after the boundary is still folded in" do
      actor = admin()
      page = published_page(actor)
      before = Chain.latest_anchor("page", page.id, page.org_id)

      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      # The other side of the same filter: a boundary that excluded real new
      # rows would freeze the chain silently, and every test above would pass.
      now = Chain.latest_anchor("page", page.id, page.org_id)
      assert now.version_count == before.version_count + 1
      refute now.chain_hash == before.chain_hash
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "a below-boundary row does not stop later rows being folded" do
      actor = admin()
      page = published_page(actor)
      before = Chain.latest_anchor("page", page.id, page.org_id)

      # Both directions of the predicate in one document. With only the two
      # tests above, a filter that returned nothing whenever a below-boundary
      # row existed would pass both — and would silently stop anchoring.
      backdated_version!(page)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      capture_log(fn -> :ok = Chain.anchor(page) end)

      now = Chain.latest_anchor("page", page.id, page.org_id)
      assert now.version_count == before.version_count + 1
      refute now.last_version_id == before.last_version_id
    end

    test "a row tying the boundary's timestamp is ordered by id, not dropped" do
      actor = admin()
      page = published_page(actor)
      before = Chain.latest_anchor("page", page.id, page.org_id)

      # `version_inserted_at` is not unique, so the fold's tiebreak is the id.
      # A row sharing the boundary's timestamp must be folded when its id sorts
      # after the boundary's, and skipped when it sorts before — dropping the
      # tiebreak entirely leaves the plain cases above green.
      after_id = backdated_version!(page, before.last_version_at)
      capture_log(fn -> :ok = Chain.anchor(page) end)
      now = Chain.latest_anchor("page", page.id, page.org_id)

      if after_id.id > before.last_version_id do
        assert now.version_count == before.version_count + 1
        assert now.last_version_id == after_id.id
      else
        assert now.version_count == before.version_count
        assert now.last_version_id == before.last_version_id
      end
    end

    test "minting says so out loud instead of leaving it for a later audit" do
      page = published_page(admin())
      backdated_version!(page)

      log = capture_log(fn -> :ok = Chain.anchor(page) end)

      assert log =~ "History chain skew"
      assert log =~ page.id
      # The count is the actionable part of the message; the prose around it is
      # not, so pin the number rather than only the wording.
      assert log =~ "1 version row(s)"
    end

    # The earlier anchor committed to an order the table no longer holds, so it
    # can never reproduce — unfixable by any resume strategy, and the verdict
    # stays red. What it must not be is a bare "hash mismatch" an operator
    # cannot tell apart from doctored content.
    test "verification names the rows that appeared inside the anchored range" do
      page = published_page(admin())
      backdated_version!(page)

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "1 version row(s) sort inside the anchored range"

      # `verify_loaded/4` answers from a loaded list rather than a count query.
      # The two must agree, or the trail and `mix kiln.audit.verify` report
      # different reasons for the same document.
      trail = KilnCMS.Governance.trail("page", page.id, page.org_id)
      assert {:tampered, ^reason} = trail.chain
    end

    test "ordinary content tampering is NOT relabelled as a range skew" do
      page = published_page(admin())

      KilnCMS.Repo.update_all(
        from(v in "pages_versions",
          where: v.version_source_id == type(^page.id, :binary_id),
          update: [set: [changes: type(^%{"title" => "Doctored"}, :map)]]
        ),
        []
      )

      # Doctored content and a spliced row are both tampering, but they call for
      # different investigations. Reporting the wrong one is worse than the bare
      # message this diagnostic replaced.
      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      refute reason =~ "sort inside the anchored range"
    end

    test "the boundary survives its own version row being deleted" do
      actor = admin()
      page = published_page(actor)
      before = Chain.latest_anchor("page", page.id, page.org_id)

      # `CoalesceAutosaveVersions` destroys superseded autosave rows on every
      # debounced save, so the row an anchor ended on routinely stops existing.
      # Resolving the boundary through `last_version_id` would drop straight back
      # to the count resume here — on the every-write configuration, the fix
      # would be inert exactly where it is needed.
      KilnCMS.Repo.delete_all(
        from(v in "pages_versions",
          where: v.id == type(^before.last_version_id, :binary_id)
        )
      )

      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      now = Chain.latest_anchor("page", page.id, page.org_id)
      assert now.version_count == before.version_count + 1
      refute now.last_version_id == before.last_version_id
    end

    test "an anchor with no recorded boundary still resumes by count" do
      actor = admin()
      page = published_page(actor)
      anchor = Chain.latest_anchor("page", page.id, page.org_id)

      # Anchors minted before #598 carry no boundary timestamp, so there is no
      # position to resume from and the fold falls back to the pre-#598 count
      # offset rather than re-folding the whole history onto a seed that already
      # covers it. Survives only until each document's next anchor.
      KilnCMS.Repo.update_all(
        from(a in "history_anchors", where: a.id == type(^anchor.id, :binary_id)),
        set: [last_version_at: nil]
      )

      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      now = Chain.latest_anchor("page", page.id, page.org_id)
      assert now.version_count == anchor.version_count + 1
      assert now.last_version_at
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # The boundary steers which rows the next anchor covers, so it is signed.
    # Without that, one UPDATE to an unsigned column repoints the resume past
    # every future version: `fresh` stays empty, the chain freezes, and the
    # document keeps reading :verified while its history is rewritten freely.
    for {column, label} <- [last_version_at: "timestamp", last_version_id: "id"] do
      test "repointing the boundary #{label} breaks the anchor signature" do
        page = published_page(admin())
        anchor = Chain.latest_anchor("page", page.id, page.org_id)
        assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

        value =
          case unquote(column) do
            :last_version_at -> ~U[3000-01-01 00:00:00.000000Z]
            :last_version_id -> Ecto.UUID.dump!(Ecto.UUID.generate())
          end

        KilnCMS.Repo.update_all(
          from(a in "history_anchors", where: a.id == type(^anchor.id, :binary_id)),
          set: [{unquote(column), value}]
        )

        assert {:tampered, "anchor signature does not verify"} =
                 Chain.verify(Page, "page", page.id, page.org_id)
      end
    end
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
