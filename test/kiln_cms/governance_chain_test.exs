defmodule KilnCMS.Governance.ChainTest do
  @moduledoc """
  Tamper-evident history anchors (#356): minted signed on publish, and
  verification detects altered / deleted anchored versions.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  require Ash.Query
  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.Governance.Chain
  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.Provenance.Canonical
  alias KilnCMS.Provenance.Signer

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

  # An anchored page an editor can still autosave: published (so a publish
  # anchor exists and the coalescing tests have a boundary to respect), then
  # unpublished back to draft (`published -> draft` is the transition the state
  # machine offers; `return_to_draft` only comes back from `:in_review`).
  #
  # `:autosave` refuses a published row outright (#1015) — the action writes
  # content and fires nothing, which is safe for a draft and not for live
  # content — so publish-then-autosave is no longer a sequence that can happen.
  # This is what the tests were reaching for: an anchor already in the chain,
  # followed by a run of autosaves.
  defp anchored_draft(actor) do
    page = published_page(actor)
    CMS.unpublish_page!(page, actor: actor)
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

  # `ON DELETE RESTRICT` on `prev_anchor_id` blocks the deletions several tests
  # need to perform in order to check what happens *after* one. Dropping it
  # models the threat these tests are about — an attacker with database control,
  # who can drop a constraint — rather than working around the fix. The sandbox
  # rolls the DDL back with the test.
  defp drop_prev_anchor_constraint! do
    KilnCMS.Repo.query!(
      "ALTER TABLE history_anchors DROP CONSTRAINT history_anchors_prev_anchor_id_fkey"
    )
  end

  # A published page with four anchors, positions 1..4, each covering strictly
  # more versions than the last.
  defp four_anchor_page(admin: actor) do
    page = published_page(actor)

    page =
      Enum.reduce(~w(Second Third Fourth), page, fn title, acc ->
        acc = CMS.update_page!(acc, %{title: title}, actor: actor)
        :ok = Chain.anchor(acc)
        acc
      end)

    assert Chain.anchors("page", page.id, page.org_id) |> Enum.map(& &1.sequence) == [4, 3, 2, 1]
    page
  end

  # Delete the anchors at `positions` and null the survivor's link columns, so
  # every remaining link resolves — what an attacker excising a run would do.
  defp excise_positions!(page, positions) do
    KilnCMS.Repo.update_all(
      from(a in "history_anchors",
        where:
          a.source_id == type(^page.id, :binary_id) and
            a.sequence == ^(Enum.max(positions) + 1)
      ),
      set: [prev_anchor_id: nil, prev_anchor_digest: nil]
    )

    KilnCMS.Repo.delete_all(
      from(a in "history_anchors",
        where: a.source_id == type(^page.id, :binary_id) and a.sequence in ^positions
      )
    )
  end

  # Exchange two anchors' positions, keeping the run contiguous.
  defp swap_positions!(a, b) do
    set_position!(a, -1)
    set_position!(b, a.sequence)
    set_position!(a, b.sequence)
  end

  # Scoped to the one anchor by id. Filtering on `sequence` alone would rewrite
  # every anchor at that position in every org, which is safe only while a test
  # happens to create exactly one document.
  defp set_position!(anchor, position) do
    KilnCMS.Repo.update_all(
      from(a in "history_anchors", where: a.id == type(^anchor.id, :binary_id)),
      set: [sequence: position]
    )
  end

  # Drop the signing key for the rest of the test: the anchors already minted
  # keep their signatures, so this is only usable before any are written.
  defp unsign! do
    previous = Application.get_env(:kiln_cms, KilnCMS.Provenance)
    Application.put_env(:kiln_cms, KilnCMS.Provenance, Keyword.delete(previous, :signing_key))
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Provenance, previous) end)
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

  # Write a signature onto an already-seeded version row. Seeding bypasses the
  # `SignVersion` change (that is the point — a seeded row models one that did
  # not come through the write path), so the tests that need a signature put one
  # there explicitly.
  defp sign_version!(version, signature, key_id) do
    KilnCMS.Repo.update_all(
      from(v in "pages_versions", where: v.id == type(^version.id, :binary_id)),
      set: [chain_signature: signature, chain_key_id: key_id]
    )
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
      # Capture and restore rather than `delete_env`: deleting falls back to the
      # compiled default (`false`), not whatever was actually configured when the
      # suite started — silently flipping the flag off for every test that runs
      # after this `describe` block if anything ever configures it `true` (#611).
      prev = Application.get_env(:kiln_cms, :audit_anchor_every_write)
      Application.put_env(:kiln_cms, :audit_anchor_every_write, true)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:kiln_cms, :audit_anchor_every_write),
          else: Application.put_env(:kiln_cms, :audit_anchor_every_write, prev)
      end)

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
      page = anchored_draft(actor)
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
      page = anchored_draft(actor)

      page = autosave!(page, "First autosave", actor)
      anchor = Chain.latest_anchor("page", page.id, page.org_id)
      anchored = anchored_version_ids(page, anchor)
      digests = version_digests(page, anchored)

      # Or the comparison below is `%{} == %{}` and holds for the trivial
      # reason that it selected nothing. Cross-checked against a number the
      # helper did not compute: create + publish + unpublish + the first
      # autosave.
      assert length(anchored) == anchor.version_count
      assert anchor.version_count == 4

      _page = page |> autosave!("Second autosave", actor) |> autosave!("Third", actor)

      # The rows an anchor committed to must still exist, byte-identical in
      # every field the item digest folds. Asserted directly rather than only
      # through the verdict: a future change could make `verify/4` tolerant
      # without making the history honest.
      assert version_digests(page, anchored) == digests
    end

    test "a never-published draft is protected the same way" do
      # The shape the flag actually produces in the editor. `:autosave` refuses
      # a non-draft row outright (#1015), so a published page is not what
      # autosave runs against — and with no publish there is no non-autosave
      # version to bound the run either, so the anchor is the ONLY thing
      # holding the line.
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
      page = anchored_draft(actor)

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

  # #910: `KilnCMS.Firing.Engine.fire/2` recomputes `search_text` against a
  # fragment-expanded tree via a narrow `:reindex_search_text` action — a
  # background write PaperTrail already ignores, so `AnchorVersion` must
  # ignore it too, the same reason `:set_oembed_metadata` is in
  # `@versionless_actions`: without it, a fire (or re-fire) of a document with
  # no PRIOR anchor mints one attributed to `actor_id: nil`, for a write that
  # is not an edit at all.
  describe "reindex_search_text does not extend the anchor chain (#910)" do
    test "firing a document with no prior anchor, whose search_text actually changes, mints no anchor" do
      actor = admin()

      shared =
        CMS.create_page!(
          %{
            title: "Shared",
            slug: "anchor-frag-shared-#{System.unique_integer([:positive])}",
            blocks: [%{"_type" => "heading", "text" => "Fragmentword"}]
          },
          actor: actor
        )
        |> then(&CMS.publish_page!(&1, %{}, actor: actor))

      host =
        CMS.create_page!(
          %{
            title: "Host",
            slug: "anchor-frag-host-#{System.unique_integer([:positive])}",
            blocks: [%{"_type" => "fragment", "ref" => %{"type" => "page", "id" => shared.id}}]
          },
          actor: actor
        )

      # `audit_anchor_every_write` is off by default, and `host` was never
      # published (the only other anchor source), so it starts with none.
      assert is_nil(Chain.latest_anchor("page", host.id, host.org_id))

      prev = Application.get_env(:kiln_cms, :audit_anchor_every_write)
      Application.put_env(:kiln_cms, :audit_anchor_every_write, true)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:kiln_cms, :audit_anchor_every_write),
          else: Application.put_env(:kiln_cms, :audit_anchor_every_write, prev)
      end)

      # `host`'s raw search_text has no fragment words (a bare `%Fragment{}`
      # block's own search_text/1 is ""), so this fire's `reindex_search_text`
      # genuinely writes — the case that must NOT reach `AnchorVersion`.
      {:ok, _artifacts} = KilnCMS.Firing.Engine.fire(host)

      assert Ash.reload!(host, authorize?: false).search_text =~ "Fragmentword"
      assert is_nil(Chain.latest_anchor("page", host.id, host.org_id))
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
      page = anchored_draft(actor)

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
      page = anchored_draft(actor)

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
      page = anchored_draft(actor)

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
      page = anchored_draft(actor)

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
      page = anchored_draft(actor)

      page = autosave!(page, "One", actor)
      :ok = Chain.anchor(page)
      anchor = Chain.latest_anchor("page", page.id, page.org_id)
      anchored = anchored_version_ids(page, anchor)
      digests = version_digests(page, anchored)

      # `audit_anchors_enabled: false` stops anchoring; it does not delete the
      # anchors already minted, and they still commit to what they commit to.
      # Reading `[]` here because the feature is "off" would let coalescing eat
      # them and red the document the moment the switch came back on.
      #
      # Capture and restore rather than `delete_env` (#611) — see the
      # `anchor_every_write` setup above for why deleting is lossy.
      prev = Application.get_env(:kiln_cms, :audit_anchors_enabled)
      Application.put_env(:kiln_cms, :audit_anchors_enabled, false)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:kiln_cms, :audit_anchors_enabled),
          else: Application.put_env(:kiln_cms, :audit_anchors_enabled, prev)
      end)

      _page = page |> autosave!("Two", actor) |> autosave!("Three", actor)

      if is_nil(prev),
        do: Application.delete_env(:kiln_cms, :audit_anchors_enabled),
        else: Application.put_env(:kiln_cms, :audit_anchors_enabled, prev)

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
    # Capture and restore rather than `delete_env` (#611) — see the
    # `anchor_every_write` setup above for why deleting is lossy.
    prev = Application.get_env(:kiln_cms, :audit_anchors_enabled)
    Application.put_env(:kiln_cms, :audit_anchors_enabled, false)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:kiln_cms, :audit_anchors_enabled),
        else: Application.put_env(:kiln_cms, :audit_anchors_enabled, prev)
    end)

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

      # PR #669 got this as far as "not double-folded": the row was skipped and
      # the anchor was at least honest about it. #598 finishes the job — the
      # assigned fold order means a late row is in no anchor's list, so this
      # anchor FOLDS it, at the tail, where it cannot displace anything the
      # previous anchor committed to.
      refute now.id == before.id
      assert now.version_count == before.version_count + 1
      refute now.chain_hash == before.chain_hash
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
      # Both rows, since #598: the one after the boundary AND the late one.
      assert now.version_count == before.version_count + 2
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

      # Since #598 the tiebreak no longer decides WHETHER the row is folded —
      # a row in no anchor's list is folded either way. It still decides where
      # it sorts within the tail, and therefore which id the boundary lands on.
      assert now.version_count == before.version_count + 1

      if after_id.id > before.last_version_id,
        do: assert(now.last_version_id == after_id.id),
        else: assert(now.last_version_id in [after_id.id, before.last_version_id])
    end

    test "a folded late row is no longer reported as skew" do
      page = published_page(admin())
      backdated_version!(page)

      log = capture_log(fn -> :ok = Chain.anchor(page) end)

      # The skew warning was PR #669's consolation prize: it could not fold the
      # row, so it said so. #598 folds it, and warning about a condition that has
      # just been repaired is noise an operator learns to ignore.
      refute log =~ "History chain skew"
      assert Chain.latest_anchor("page", page.id, page.org_id).version_count == 3
    end

    # #598 assigned the fold order, and this is the contract that replaced the
    # old one. A row appearing inside the anchored range no longer breaks the
    # recomputed prefix — it is in no anchor's list, so it sorts to the tail and
    # every earlier anchor still reproduces. What decides the verdict now is the
    # ROW'S OWN SIGNATURE, and the three answers are genuinely different.
    #
    # An unsigned row is the one that used to read `{:tampered, …}` for no
    # reason: clock skew produced exactly this shape. It must not fail, and it
    # must not silently pass either.
    test "an unsigned row inside the anchored range is flagged, not failed" do
      page = published_page(admin())
      backdated_version!(page)

      assert Chain.verify(Page, "page", page.id, page.org_id) == :unverifiable

      # `verify_loaded/4` answers from a loaded list rather than a count query.
      # The two must agree, or the trail and `mix kiln.audit.verify` report
      # different things about the same document.
      trail = KilnCMS.Governance.trail("page", page.id, page.org_id)
      assert trail.chain == :unverifiable
    end

    # The detection the assigned order would otherwise have cost. A row somebody
    # inserted into the table carries no signature this deployment's key
    # produces, and that is unambiguous evidence.
    test "a row carrying a signature that does not verify is tampering" do
      page = published_page(admin())
      version = backdated_version!(page)

      # A syntactically valid signature over the WRONG payload — what a splice
      # looks like if whoever wrote it also tried to forge the column.
      {bogus, key_id} =
        KilnCMS.Governance.VersionSignature.sign(%{
          org_id: page.org_id,
          resource_type: "page",
          source_id: page.id,
          version_id: Ash.UUID.generate(),
          version_inserted_at: version.version_inserted_at
        })

      sign_version!(version, bogus, key_id)

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "did not come from this system"
    end

    # The end-to-end shape of the bug, driven through `Chain.anchor/1` rather
    # than through a hand-set verdict: publish, have a row arrive below the
    # boundary, anchor again. Before #598 the second anchor could not repair it
    # and the document stayed red forever — "re-anchor → still tampered,
    # permanently", reproduced 10/10 in the original review.
    test "re-anchoring folds a late row at the tail and clears the verdict" do
      page = published_page(admin())
      version = backdated_version!(page)

      {signature, key_id} =
        KilnCMS.Governance.VersionSignature.sign(
          KilnCMS.Governance.VersionSignature.identity(version, "page")
        )

      sign_version!(version, signature, key_id)

      # The next anchor folds it — at the tail, where it cannot displace
      # anything an earlier anchor committed to.
      capture_log(fn -> :ok = Chain.anchor(page) end)

      assert Chain.verify(Page, "page", page.id, page.org_id) == :verified

      head = Chain.latest_anchor("page", page.id, page.org_id)
      assert version.id in head.folded_version_ids
      # And the count now describes the same set the hash does, which is the
      # `unanchored_tail/2` over-reporting #670 folds in.
      assert head.version_count == length(Chain.versions_asc(Page, page.id, page.org_id))
    end

    # And the actual #598 fix: a row that genuinely arrived late, signed by this
    # system at the moment it was written, is folded at the tail by the next
    # anchor and the document stays verified. This is the case that used to read
    # permanently tampered with nothing wrong.
    test "a validly signed late row leaves the chain verified" do
      page = published_page(admin())
      version = backdated_version!(page)

      {signature, key_id} =
        KilnCMS.Governance.VersionSignature.sign(
          KilnCMS.Governance.VersionSignature.identity(version, "page")
        )

      sign_version!(version, signature, key_id)

      assert Chain.verify(Page, "page", page.id, page.org_id) == :verified
    end

    # The counts the closure defers can themselves fail — the realistic case is
    # a statement timeout on a large version table mid-audit. The rescue has to
    # catch at invocation time, not construction time: `mix kiln.audit.verify`
    # walks every document, and before #705 this raise aborted the sweep on
    # exactly the verdict it exists to surface.
    test "a failing range count degrades to the bare mismatch instead of raising" do
      page = published_page(admin())
      anchor = Chain.latest_anchor("page", page.id, page.org_id)

      # `CountlessVersions` reads fine but raises on `Ash.count!`. Feed it
      # enough rows that the fold reproduces a full-length history whose hash
      # cannot match the anchor's, so the verdict reaches the mismatch branch
      # and invokes the count closure.
      rows =
        for offset <- 1..(anchor.version_count + 1) do
          %KilnCMS.CountlessVersions.Version{
            id: Ash.UUID.generate(),
            version_source_id: page.id,
            version_action_name: "update",
            version_inserted_at: DateTime.add(~U[2001-01-01 00:00:00.000000Z], offset, :hour),
            changes: %{"title" => "Fabricated #{offset}"}
          }
        end

      on_exit(&KilnCMS.CountlessVersions.clear_rows/0)
      KilnCMS.CountlessVersions.put_rows(rows)

      {verdict, log} =
        with_log(fn ->
          Chain.verify(KilnCMS.CountlessVersions, "page", page.id, page.org_id)
        end)

      assert {:tampered, reason} = verdict
      assert reason == "anchored history does not reproduce the recorded chain hash"
      refute reason =~ "sort inside the anchored range"
      assert log =~ "History chain range count failed"
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

      # NOT `:verified` — and that is the point of #666's signature sweep, not a
      # regression. `last_version_at` is inside the signed payload, so the
      # `UPDATE` above (which stands in for an anchor minted before the column
      # existed) is itself detectable now that every anchor's signature is
      # checked, not just the head's. A genuine pre-#598 anchor was signed
      # without the column and verifies fine; this simulation rewrites a signed
      # one, which is exactly what the sweep exists to notice.
      assert {:tampered, "anchor signature does not verify"} =
               Chain.verify(Page, "page", page.id, page.org_id)
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
    test "Postgres refuses to delete an anchor a SURVIVING anchor names" do
      # `ON DELETE RESTRICT` on `prev_anchor_id` (#597). This is the property it
      # actually buys, stated precisely because the obvious stronger reading is
      # false — see the next test.
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      [_newest | [older | _]] = Chain.anchors("page", page.id, page.org_id)

      assert_raise Postgrex.Error, ~r/foreign key constraint/, fn ->
        KilnCMS.Repo.delete_all(
          from(a in "history_anchors", where: a.id == type(^older.id, :binary_id))
        )
      end
    end

    test "RESTRICT does NOT block deleting the whole chain in one statement" do
      # Characterised because it is the natural thing to assume and it is wrong:
      # Postgres checks the constraint after the statement's rows are gone, so a
      # `DELETE … WHERE source_id = …` that removes referrer and referent
      # together succeeds. What RESTRICT buys is that a MIDDLE anchor cannot be
      # removed on its own — the attacker must take its successor too, which is
      # the shape `chain_intact/1`'s sequence check catches.
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.source_id == type(^page.id, :binary_id))
      )

      assert :unanchored = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "deleting a predecessor anchor is detected" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      [newest | older] = Chain.anchors("page", page.id, page.org_id)
      assert older != [], "expected more than one anchor"

      ids = Enum.map(older, & &1.id)

      # Past the `RESTRICT` deliberately: the threat model is an attacker with
      # database control, who can drop a constraint. The constraint raises the
      # cost; `chain_intact/1` is what still notices afterwards, and it also
      # covers anchors that predate the constraint.
      drop_prev_anchor_constraint!()

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id in ^Enum.map(ids, &Ecto.UUID.dump!/1))
      )

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "anchor chain broken"
      assert reason =~ newest.prev_anchor_id
    end

    test "removing a middle anchor AND its successor is caught by the signature sweep" do
      # The case the predecessor links alone cannot catch: with the successor
      # gone too, every surviving link resolves. On a SIGNED deployment the
      # attacker has to null the survivor's link columns to get there, and those
      # are inside its signed payload — so checking every anchor's signature,
      # not just the head's, is what catches it (#666).
      actor = admin()
      page = four_anchor_page(admin: actor)

      drop_prev_anchor_constraint!()
      excise_positions!(page, [2, 3])

      assert {:tampered, "anchor signature does not verify"} =
               Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "the same removal on an UNSIGNED deployment is caught by the position gap" do
      # Where the position check earns its place. With no signing key there is no
      # signature to break, so nulling the survivor's link columns is free and
      # every surviving link resolves. The run is then `[4, 1]`, and the hole in
      # it is the only thing left that says an anchor is missing.
      #
      # `chain_intact/1` runs before `verdict/5`'s `:unsigned` short-circuit, so
      # the finding is reported rather than swallowed by "we cannot judge".
      unsign!()

      page = four_anchor_page(admin: admin())

      drop_prev_anchor_constraint!()
      excise_positions!(page, [2, 3])

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "anchor sequence is not contiguous"
    end

    test "an anchor nobody can vouch for stops the chain reading verified" do
      # The hole the first pass at this left open, and it needed no DELETE at
      # all. `anchor_digest/1` covers neither `key_id` nor `sequence`, so an
      # attacker nulls a non-head anchor's signature to make it unjudgeable,
      # renumbers it into the baseline position, and nothing objects: the
      # promoted anchor is skipped by the signature sweep, and its short
      # `version_count` becomes the anchored prefix.
      #
      # Now an unjudgeable anchor floors the whole chain. `:unsigned` is not a
      # clean bill — it is the honest one.
      actor = admin()
      page = four_anchor_page(admin: actor)

      [newest | _] = Chain.anchors("page", page.id, page.org_id)
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      KilnCMS.Repo.update_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id)),
        set: [signature: nil]
      )

      assert :unsigned = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "an anchor minted with no boundary still verifies against its own signature" do
      # `mint/3` signs the v4 payload unconditionally, but a fold that covers no
      # version rows records no boundary — so gating the v4 candidate on
      # `last_version_at` made a freshly minted anchor unverifiable against the
      # signature it had just been given. Head-only checking hid that until the
      # head moved past it; sweeping every anchor would have made it permanent,
      # with no destroy action to repair it.
      actor = admin()
      page = published_page(actor)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.source_id == type(^page.id, :binary_id))
      )

      KilnCMS.Repo.delete_all(
        from(v in "pages_versions", where: v.version_source_id == type(^page.id, :binary_id))
      )

      :ok = Chain.anchor(page)

      minted = Chain.latest_anchor("page", page.id, page.org_id)
      refute minted.last_version_at, "expected an anchor over no versions to record no boundary"
      assert minted.signature

      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "an anchor signed with a key we do not hold floors it too" do
      actor = admin()
      page = four_anchor_page(admin: actor)
      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.update_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id)),
        set: [key_id: "a-key-this-deployment-has-never-held"]
      )

      # Indistinguishable from a rotation whose outgoing key was never
      # registered, which is exactly why it must not read `:verified`.
      assert :unverifiable = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "real hash tampering is still reported on an unsigned deployment" do
      # The floor must not swallow the one check that needs no key. Folding
      # attestation into the structural verdict would have replaced a genuine
      # `{:tampered, …}` with a shrug on every keyless deployment.
      unsign!()

      page = four_anchor_page(admin: admin())

      KilnCMS.Repo.update_all(
        from(v in "pages_versions",
          where: v.version_source_id == type(^page.id, :binary_id),
          where: v.version_action_name == "create"
        ),
        set: [changes: %{"title" => "Doctored"}]
      )

      assert {:tampered, _} = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "a short anchor cannot be renumbered into the baseline position" do
      # Contiguity alone is satisfied by any permutation, and a permutation is
      # what would promote an early, short anchor to the head — putting the
      # doctored versions outside the anchored prefix. `version_count` rising
      # with position is what forbids it. Unsigned, so the swap itself is free
      # and the invariant is the only thing standing.
      unsign!()

      page = four_anchor_page(admin: admin())
      [newest | _] = anchors = Chain.anchors("page", page.id, page.org_id)
      oldest = List.last(anchors)

      assert newest.version_count > oldest.version_count

      swap_positions!(newest, oldest)

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "anchor sequence is out of order"
    end

    test "rewriting inserted_at no longer changes the verification baseline" do
      # #666's other half. `inserted_at` is written by the database and attested
      # by nothing, so while anchors were READ in that order, backdating the
      # newest one made an older, shorter anchor the baseline — the doctored
      # versions then fell outside the anchored prefix and were never hashed,
      # with nothing deleted at all. Reading by the signed `sequence` closes it.
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.update_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id)),
        set: [inserted_at: ~U[2000-01-01 00:00:00.000000Z]]
      )

      [still_newest | _] = Chain.anchors("page", page.id, page.org_id)
      assert still_newest.id == newest.id
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
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

    # The route #597 filed and #666 closed. An attacker deletes only the anchors
    # covering the doctored version — the newest, which nothing points at — so
    # `chain_intact/1` sees no dangling link and the surviving prefix still folds
    # to its recorded hash. Nothing INSIDE the document can tell that apart from
    # a younger chain; what catches it is the checkpoint witness.
    #
    # This test asserted `:verified` until #666. It is left in the same shape on
    # purpose: the inversion is the acceptance criterion.
    test "deleting the NEWEST anchor is not detected without a witness" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      # No checkpoint was ever minted for this org, so there is nothing outside
      # the document to compare against.
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "deleting the NEWEST anchor IS detected once a checkpoint witnessed it" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)

      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "anchor chain truncated"
    end

    # The laundering route the truncation exists to serve: doctor a version,
    # delete the anchors that cover it, wait for the next write to re-anchor from
    # the surviving prefix. Before the witness the final verdict was `:verified`.
    test "re-anchoring over doctored history after a truncation stays tampered" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)

      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      page = CMS.update_page!(page, %{title: "Third"}, actor: actor)
      :ok = Chain.anchor(page)

      assert {:tampered, _reason} = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # Reached with UPDATE rather than DELETE: rewriting `resource_type` takes the
    # newest anchors out of the set the query returns, which is the same attack
    # and used to read the same way.
    test "hiding the newest anchor by rewriting its resource_type is detected" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)

      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.update_all(
        from(a in "history_anchors",
          where: a.id == type(^newest.id, :binary_id),
          update: [set: [resource_type: "page_x"]]
        ),
        []
      )

      assert {:tampered, _reason} = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # Was `:unanchored` — indistinguishable from a document anchored for the
    # first time, which is what made a wholesale wipe a laundering route rather
    # than an alarm.
    test "wiping every anchor on a witnessed document is tampered, not unanchored" do
      page = published_page(admin())
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.source_id == type(^page.id, :binary_id))
      )

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "no anchors at all"
    end

    test "wiping every anchor on a document no checkpoint saw is still unanchored" do
      page = published_page(admin())

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.source_id == type(^page.id, :binary_id))
      )

      assert :unanchored = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # Growth past the witness is normal and must not read as tampering.
    test "anchoring past the last checkpoint stays verified" do
      actor = admin()
      page = published_page(actor)
      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)

      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # The governance trail folds an already-loaded version list through a
    # different entry point. Both have to reach the same verdict, or the
    # dashboard and `mix kiln.audit.verify` disagree about the same document.
    test "verify_loaded/4 reaches the same truncation verdict" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)
      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      versions = Chain.versions_asc(Page, page.id, page.org_id)

      assert {:tampered, _} = Chain.verify_loaded(versions, "page", page.id, page.org_id)
    end
  end

  describe "checkpoint witness (#666)" do
    test "an entry rewritten to match a truncated chain fails its inclusion proof" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)
      [newest, older] = Chain.anchors("page", page.id, page.org_id) |> Enum.take(2)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      # The obvious repair: lower the witnessed head to the surviving anchor.
      KilnCMS.Repo.update_all(
        from(e in "chain_checkpoint_entries",
          where: e.source_id == type(^page.id, :binary_id),
          update: [
            set: [
              head_anchor_id: type(^older.id, :binary_id),
              head_sequence: ^older.sequence,
              chain_hash: ^older.chain_hash,
              version_count: ^older.version_count
            ]
          ]
        ),
        []
      )

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "not included in the root"
    end

    test "an entry whose checkpoint_sequence disagrees with its checkpoint is detected" do
      actor = admin()
      page = published_page(actor)
      {:ok, _first} = Checkpoint.mint(page.org_id)

      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)
      {:ok, _second} = Checkpoint.mint(page.org_id)

      # The denormalized ordering column against the checkpoint's SIGNED one.
      KilnCMS.Repo.update_all(
        from(e in "chain_checkpoint_entries",
          where: e.source_id == type(^page.id, :binary_id) and e.head_sequence == 2,
          update: [set: [checkpoint_sequence: 99]]
        ),
        []
      )

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "claims position 99"
    end

    # Entries are read strongest-claim-first, so demoting one by renumbering it
    # cannot make a weaker claim the standing one. Before that ordering, raising
    # an old entry's `checkpoint_sequence` promoted it over the real witness.
    test "renumbering a weaker entry cannot demote the standing claim" do
      actor = admin()
      page = published_page(actor)
      {:ok, _first} = Checkpoint.mint(page.org_id)

      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)
      {:ok, _second} = Checkpoint.mint(page.org_id)

      KilnCMS.Repo.update_all(
        from(e in "chain_checkpoint_entries",
          where: e.source_id == type(^page.id, :binary_id) and e.head_sequence == 1,
          update: [set: [checkpoint_sequence: 99]]
        ),
        []
      )

      # The position-2 claim still stands and still matches, so the renumbering
      # bought nothing.
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      # Deleting the stronger entry does not hand the attacker the weaker one
      # either: it is now the standing claim, and the number they wrote on it is
      # what the cross-check against the checkpoint's signed sequence catches.
      KilnCMS.Repo.delete_all(
        from(e in "chain_checkpoint_entries",
          where: e.source_id == type(^page.id, :binary_id) and e.head_sequence == 2
        )
      )

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "claims position 99"
    end

    # An entry pointing at nothing is the state an attacker wants — no
    # checkpoint to check the proof against. Both routes to it are refused by
    # the database: `ON DELETE RESTRICT` keeps the checkpoint alive while an
    # entry names it, and the foreign key refuses a repoint at an id that does
    # not exist. `Checkpoint.attest/2` still handles the dangling case, as
    # defence in depth for a deployment whose constraints were dropped.
    test "an entry cannot be left pointing at a checkpoint that does not exist" do
      page = published_page(admin())
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      assert_raise Postgrex.Error, ~r/foreign_key_violation/, fn ->
        KilnCMS.Repo.update_all(
          from(e in "chain_checkpoint_entries",
            where: e.source_id == type(^page.id, :binary_id),
            update: [set: [checkpoint_id: type(^Ecto.UUID.generate(), :binary_id)]]
          ),
          []
        )
      end

      assert_raise Postgrex.Error, ~r/foreign_key_violation/, fn ->
        KilnCMS.Repo.delete_all(
          from(c in "chain_checkpoints", where: c.id == type(^checkpoint.id, :binary_id))
        )
      end
    end

    # The honest limit of the default `None` witness, asserted rather than
    # assumed: with the commitment in the database, an attacker who remembers
    # the second table removes the evidence along with the anchors. Configuring
    # a real sink is what makes `mix kiln.audit.checkpoint --audit` see the
    # missing rows; nothing inside `verify/4` can.
    test "deleting the entry rows removes the witness (the None-adapter limit)" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)
      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      KilnCMS.Repo.delete_all(
        from(e in "chain_checkpoint_entries", where: e.source_id == type(^page.id, :binary_id))
      )

      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "a truncated head is not re-witnessed by the next checkpoint" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _first} = Checkpoint.mint(page.org_id)
      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      log = capture_log(fn -> {:ok, _second} = Checkpoint.mint(page.org_id) end)
      assert log =~ "heads at anchor position"

      # The evidence still stands: the second checkpoint recorded no lower entry
      # to overwrite it with.
      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "anchor chain truncated"
    end

    test "an unchanged document gets no new entry, and still verifies" do
      page = published_page(admin())
      {:ok, _first} = Checkpoint.mint(page.org_id)
      {:ok, _second} = Checkpoint.mint(page.org_id)

      entries =
        KilnCMS.Repo.all(
          from(e in "chain_checkpoint_entries",
            where: e.source_id == type(^page.id, :binary_id),
            select: e.head_sequence
          )
        )

      assert entries == [1]
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "checkpoints chain to each other and are signed" do
      page = published_page(admin())
      {:ok, first} = Checkpoint.mint(page.org_id)

      _page = CMS.update_page!(page, %{title: "Second"}, actor: admin())
      {:ok, second} = Checkpoint.mint(page.org_id)

      assert second.sequence == first.sequence + 1
      assert second.prev_checkpoint_id == first.id
      assert second.prev_checkpoint_digest == Checkpoint.digest(first)
      refute is_nil(second.signature)
      assert :ok = Checkpoint.checkpoint_attestation(second, page.org_id)
    end

    test "rewriting a checkpoint's root breaks its signature and floors the verdict" do
      page = published_page(admin())
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      KilnCMS.Repo.update_all(
        from(c in "chain_checkpoints",
          where: c.id == type(^checkpoint.id, :binary_id),
          update: [set: [root: "doctored"]]
        ),
        []
      )

      # The inclusion proof no longer reconstructs the (rewritten) root, so this
      # is caught before the signature is even consulted.
      assert {:tampered, _reason} = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "an unsigned checkpoint floors the verdict rather than being skipped" do
      page = published_page(admin())
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      KilnCMS.Repo.update_all(
        from(c in "chain_checkpoints",
          where: c.id == type(^checkpoint.id, :binary_id),
          update: [set: [signature: nil, key_id: nil]]
        ),
        []
      )

      assert :unsigned = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # The hole a head-versus-head comparison leaves. Anchor positions are refilled
    # by `next_sequence/1`, so after the truncation two ordinary publishes put the
    # head PAST the witnessed position with a contiguous chain underneath it. The
    # comparison has to be at the witnessed position, not at the head.
    test "re-anchoring PAST the witnessed position is still detected" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)
      [newest | _] = Chain.anchors("page", page.id, page.org_id)
      assert newest.sequence == 2

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      # Two writes: position 2 is refilled and 3 is minted, so the head is now
      # beyond what the checkpoint witnessed.
      page = CMS.update_page!(page, %{title: "Third"}, actor: actor)
      :ok = Chain.anchor(page)
      page = CMS.update_page!(page, %{title: "Fourth"}, actor: actor)
      :ok = Chain.anchor(page)

      assert [3, 2, 1] = Chain.anchors("page", page.id, page.org_id) |> Enum.map(& &1.sequence)

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "is not the one checkpoint"
    end

    # ...and the next scheduled checkpoint must not launder it by recording the
    # replacement as the new truth.
    test "the next checkpoint does not re-witness a substituted anchor" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _first} = Checkpoint.mint(page.org_id)
      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      page = CMS.update_page!(page, %{title: "Third"}, actor: actor)
      :ok = Chain.anchor(page)

      log = capture_log(fn -> {:ok, _second} = Checkpoint.mint(page.org_id) end)
      assert log =~ "no longer carries the anchor"

      assert {:tampered, _reason} = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # `proof` is a `jsonb[]`, so Postgres takes any JSON and Ecto raises on load.
    # An unreadable witness must floor the verdict, not vanish — otherwise one
    # UPDATE is cheaper than the deletion the whole mechanism defends against.
    test "an entry rewritten into an unloadable shape floors the verdict" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)
      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      KilnCMS.Repo.query!(
        "UPDATE chain_checkpoint_entries SET proof = ARRAY['\"not-a-map\"'::jsonb] " <>
          "WHERE source_id = $1",
        [Ecto.UUID.dump!(page.id)]
      )

      {verdict, log} =
        with_log(fn -> Chain.verify(Page, "page", page.id, page.org_id) end)

      assert verdict == :unverifiable
      assert log =~ "cannot be verified against its witness"
    end

    # A forged checkpoint needs no signing key if an empty proof is accepted:
    # set `root` to the leaf you want attested and pair it with `proof = '{}'`.
    test "an entry with no inclusion proof is rejected on a multi-document checkpoint" do
      actor = admin()
      page = published_page(actor)
      _other = published_page(actor)

      {:ok, checkpoint} = Checkpoint.mint(page.org_id)
      assert checkpoint.document_count == 2

      KilnCMS.Repo.query!(
        "UPDATE chain_checkpoint_entries SET proof = '{}' WHERE source_id = $1",
        [Ecto.UUID.dump!(page.id)]
      )

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "no inclusion proof"
    end

    # A real Merkle tree, not the degenerate single-leaf one every other test
    # builds — so the proof machinery is actually exercised end to end.
    test "inclusion proofs verify across a multi-document checkpoint" do
      actor = admin()
      pages = for _ <- 1..5, do: published_page(actor)

      {:ok, checkpoint} = Checkpoint.mint(hd(pages).org_id)
      assert checkpoint.document_count == 5

      entries = Checkpoint.entries(checkpoint, hd(pages).org_id)
      assert length(entries) == 5
      assert Enum.all?(entries, &(&1.proof != []))

      for page <- pages do
        assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
      end
    end

    # The anchoring master switch stops anchoring; it does not claim history was
    # rewritten. Without the gate every witnessed document went red at once.
    test "turning off anchoring does not turn witnessed documents tampered" do
      page = published_page(admin())
      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)

      Application.put_env(:kiln_cms, :audit_anchors_enabled, false)
      on_exit(fn -> Application.put_env(:kiln_cms, :audit_anchors_enabled, true) end)

      assert :unanchored = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "the kill switch makes the witness inert" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      {:ok, _checkpoint} = Checkpoint.mint(page.org_id)
      [newest | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^newest.id, :binary_id))
      )

      Application.put_env(:kiln_cms, :governance_checkpoints_enabled, false)
      on_exit(fn -> Application.put_env(:kiln_cms, :governance_checkpoints_enabled, true) end)

      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end
  end

  describe "forged head anchors (#708)" do
    # The verdict's baseline is the head anchor, and INSERT on history_anchors
    # is enough to supply the head: chain_hash refolded over the doctored
    # table, link columns recomputed from the predecessor's public columns —
    # neither needs the signing key. Before #708 such a head read `:unsigned`
    # (or `:unverifiable` with a bogus key_id), which `mix kiln.audit.verify`
    # counts as a pass.
    test "an inserted unsigned head cannot downgrade a tamper verdict to :unsigned" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      doctor_versions!(page)
      forge_head!(page, %{signature: nil, key_id: nil})

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "newest attested anchor"

      # The trail's loaded-list twin must reach the same verdict, or the
      # dashboard and `mix kiln.audit.verify` disagree about the document.
      trail = KilnCMS.Governance.trail("page", page.id, page.org_id)
      assert {:tampered, ^reason} = trail.chain
    end

    # The other mask: a head signed by a key nobody holds is `:unverifiable`,
    # which the sweep also passes — same insertion, one more forged column.
    test "an inserted head under an unknown key cannot hide behind :unverifiable" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      doctor_versions!(page)

      forge_head!(page, %{
        signature: Base.encode64("not a signature"),
        key_id: "sha256:" <> String.duplicate("ab", 32)
      })

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "newest attested anchor"
    end

    # Evidence decides, not key configuration: an honest head minted unsigned
    # (`sign/1` stores the anchor unsigned and logs when the key fails to
    # resolve) over history the attested prefix still reproduces must keep
    # reading `:unsigned` — turning every key hiccup into a permanent
    # `{:tampered, …}` would train operators to ignore red.
    test "an honest unsigned head over intact attested history stays :unsigned" do
      actor = admin()
      page = published_page(actor)

      # The hiccup is mint-time only: the key is back for verification, or the
      # signed prefix would read :unverifiable rather than attested.
      prev = Application.get_env(:kiln_cms, KilnCMS.Provenance)
      Application.put_env(:kiln_cms, KilnCMS.Provenance, Keyword.delete(prev, :signing_key))
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      capture_log(fn -> :ok = Chain.anchor(page) end)
      Application.put_env(:kiln_cms, KilnCMS.Provenance, prev)

      assert :unsigned = Chain.verify(Page, "page", page.id, page.org_id)
    end
  end

  # #811: the residual #708 does NOT close. #708 constrains a forged head to the
  # newest anchor that still verifies — but only within THAT anchor's prefix. An
  # attacker with DELETE as well as INSERT moves the doctoring past it.
  describe "attested prefix short of the head (#811)" do
    test "INSERT+DELETE of the verified head still reads :unsigned" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)
      page = CMS.update_page!(page, %{title: "Third"}, actor: actor)
      :ok = Chain.anchor(page)

      [head, second | _] = Chain.anchors("page", page.id, page.org_id)
      # The counts are whatever the publish/update cadence produced; what the
      # attack needs is only that the head covers strictly more than its
      # predecessor, so there are versions outside `second`'s prefix to doctor.
      assert head.version_count > second.version_count

      # 1. Delete the verified head. Nothing references it, so the
      #    `ON DELETE RESTRICT` on `prev_anchor_id` permits it.
      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^head.id, :binary_id))
      )

      # 2. Doctor ONLY the newest version — the one beyond `second`'s prefix.
      doctor_newest_version!(page)

      # 3. Re-insert an unsigned anchor at the SAME position, refolded over the
      #    doctored table. None of it needs the signing key.
      reinsert_head!(page, second, head.sequence)

      # The hole, asserted as it stands: the surviving attested prefix
      # (versions 1-2) still reproduces, so #708's baseline is satisfied, and
      # the head is merely unsigned — which `mix kiln.audit.verify` passes.
      assert :unsigned = Chain.verify(Page, "page", page.id, page.org_id)

      # What #811 adds: the attestation demonstrably stops at the predecessor's
      # prefix, so the audit can say so instead of printing "intact (unsigned)".
      assert {:gap, attested, head_count} =
               Chain.attested_gap("page", page.id, page.org_id)

      assert attested == second.version_count
      assert head_count == head.version_count
      assert attested < head_count
    end

    test "the same doctoring WITHOUT the delete is caught outright" do
      # The counterfactual that makes the test above mean something: it is the
      # DELETE of the verified head that launders the edit. Leave the head in
      # place and the identical version rewrite is a plain tamper verdict, which
      # is the #708 property #811 is a residual of.
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)
      page = CMS.update_page!(page, %{title: "Third"}, actor: actor)
      :ok = Chain.anchor(page)

      doctor_newest_version!(page)

      assert {:tampered, _reason} = Chain.verify(Page, "page", page.id, page.org_id)
    end

    test "an equal-coverage head is not reported as a gap" do
      # `coverage_rises_with_position/1` rejects a DECREASE but permits equal
      # counts, so a head covering no more than its predecessor is reachable.
      # There are no versions beyond the attested prefix there, and reporting
      # `{:gap, n, n}` would print an empty, inverted version range.
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      [head, second | _] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.delete_all(
        from(a in "history_anchors", where: a.id == type(^head.id, :binary_id))
      )

      Ash.Seed.seed!(
        KilnCMS.CMS.HistoryAnchor,
        %{
          org_id: page.org_id,
          resource_type: "page",
          source_id: page.id,
          chain_hash: second.chain_hash,
          version_count: second.version_count,
          last_version_id: second.last_version_id,
          last_version_at: second.last_version_at,
          prev_anchor_id: second.id,
          prev_anchor_digest: Chain.anchor_digest(second),
          sequence: head.sequence,
          signature: nil,
          key_id: nil
        }
      )

      assert :none = Chain.attested_gap("page", page.id, page.org_id)
    end

    test "one UPDATE of key_id makes the whole chain unattested, not a gap" do
      # `anchor_digest/1` covers neither `key_id` nor `sequence`, so this leaves
      # every link and every sequence number intact while making every anchor
      # unjudgeable. Cheaper than the DELETE #811 describes, and it lands on
      # `:unattested` — which is why the audit reports that too, rather than
      # treating it as the milder finding.
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      KilnCMS.Repo.update_all(
        from(a in "history_anchors",
          where: a.source_id == type(^page.id, :binary_id),
          update: [set: [key_id: "sha256:deadbeef"]]
        ),
        []
      )

      assert :unverifiable = Chain.verify(Page, "page", page.id, page.org_id)
      assert :unattested = Chain.attested_gap("page", page.id, page.org_id)
    end

    test "anchoring switched off claims nothing" do
      prev = Application.get_env(:kiln_cms, :audit_anchors_enabled, true)
      Application.put_env(:kiln_cms, :audit_anchors_enabled, false)
      on_exit(fn -> Application.put_env(:kiln_cms, :audit_anchors_enabled, prev) end)

      assert :disabled = Chain.attested_gap("page", Ecto.UUID.generate(), nil)
    end

    test "a fully verified chain has no gap" do
      actor = admin()
      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
      assert :none = Chain.attested_gap("page", page.id, page.org_id)
    end

    test "a chain with nothing signed is :unattested, not a gap" do
      # The honest keyless deployment. There is no attested prefix to fall short
      # of, and the verdict already says so — reporting a gap here would fail
      # every run on every document for a deployment that made a choice.
      actor = admin()

      prev = Application.get_env(:kiln_cms, KilnCMS.Provenance)
      Application.put_env(:kiln_cms, KilnCMS.Provenance, Keyword.delete(prev, :signing_key))

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Provenance, prev) end)
      {page, _log} = with_log(fn -> published_page(actor) end)

      Application.put_env(:kiln_cms, KilnCMS.Provenance, prev)

      assert :unattested = Chain.attested_gap("page", page.id, page.org_id)
    end

    test "an unsigned anchor OLDER than the attested head is not a gap" do
      # The floor is the weakest judgement across the whole chain, so this reads
      # `:unsigned` — but the head itself is attested, so nothing is outside the
      # attested prefix and there is nothing to report.
      actor = admin()
      page = published_page(actor)

      [first] = Chain.anchors("page", page.id, page.org_id)

      KilnCMS.Repo.update_all(
        from(a in "history_anchors",
          where: a.id == type(^first.id, :binary_id),
          update: [set: [signature: nil, key_id: nil]]
        ),
        []
      )

      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)

      assert :none = Chain.attested_gap("page", page.id, page.org_id)
    end

    test "an empty chain has no gap" do
      assert :none = Chain.attested_gap("page", Ecto.UUID.generate(), nil)
    end
  end

  # Re-insert a head at a position just deleted, linked to the anchor that
  # preceded it — the DELETE half of #811, as distinct from `forge_head!`'s
  # append.
  defp reinsert_head!(page, previous, sequence) do
    refolded = Chain.compute(Page, page.id, page.org_id)

    Ash.Seed.seed!(
      KilnCMS.CMS.HistoryAnchor,
      %{
        org_id: page.org_id,
        resource_type: "page",
        source_id: page.id,
        chain_hash: refolded.chain_hash,
        version_count: refolded.version_count,
        last_version_id: refolded.last_version_id,
        last_version_at: refolded.last_version_at,
        prev_anchor_id: previous.id,
        prev_anchor_digest: Chain.anchor_digest(previous),
        sequence: sequence,
        signature: nil,
        key_id: nil
      }
    )
  end

  # Only the newest version row, so the versions inside the surviving attested
  # anchor's prefix stay byte-identical and still reproduce.
  defp doctor_newest_version!(page) do
    [newest_id] =
      KilnCMS.Repo.all(
        from(v in "pages_versions",
          where: v.version_source_id == type(^page.id, :binary_id),
          # Same total order as the fold (`version_inserted_at`, then `id`), so a
          # timestamp tie can't pick a row inside the surviving attested prefix.
          order_by: [desc: v.version_inserted_at, desc: v.id],
          limit: 1,
          select: v.id
        )
      )

    # Asserted, so a helper that silently matched nothing can't make a test pass
    # by doctoring no rows at all.
    assert {1, _} =
             KilnCMS.Repo.update_all(
               from(v in "pages_versions",
                 where: v.id == ^newest_id,
                 update: [set: [changes: type(^%{"title" => "Doctored"}, :map)]]
               ),
               []
             )
  end

  # What an attacker with INSERT can compute without the signing key: the fold
  # over the (doctored) version table, and the predecessor digest over the
  # current head's public columns.
  defp forge_head!(page, attrs) do
    [head | _] = Chain.anchors("page", page.id, page.org_id)
    refolded = Chain.compute(Page, page.id, page.org_id)

    Ash.Seed.seed!(
      KilnCMS.CMS.HistoryAnchor,
      Map.merge(
        %{
          org_id: page.org_id,
          resource_type: "page",
          source_id: page.id,
          chain_hash: refolded.chain_hash,
          version_count: refolded.version_count,
          last_version_id: refolded.last_version_id,
          last_version_at: refolded.last_version_at,
          prev_anchor_id: head.id,
          prev_anchor_digest: Chain.anchor_digest(head),
          sequence: head.sequence + 1
        },
        attrs
      )
    )
  end

  defp doctor_versions!(page) do
    KilnCMS.Repo.update_all(
      from(v in "pages_versions",
        where: v.version_source_id == type(^page.id, :binary_id),
        update: [set: [changes: type(^%{"title" => "Doctored"}, :map)]]
      ),
      []
    )
  end

  defp rewrite_author!(page, user_id) do
    KilnCMS.Repo.update_all(
      from(v in "pages_versions",
        where: v.version_source_id == type(^page.id, :binary_id),
        update: [set: [user_id: type(^user_id, :binary_id)]]
      ),
      []
    )
  end

  # `item_digest/1` folds a version's changes and ordering but NOT its author, so
  # rewriting `user_id` left the chain reading `:verified` next to attribution
  # that had been changed — most of what an editorial audit is for. A v5 anchor
  # (minted now) records a second fold over the covered versions' author and
  # action type; a pre-#713 anchor recorded none and is honestly not attested.
  describe "author attribution (#713)" do
    test "rewriting a version row's author produces a tamper verdict" do
      actor = admin()
      other = admin()
      page = published_page(actor)

      # Clean, anchored, signed: verified.
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      rewrite_author!(page, other.id)

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "author attribution"

      # The trail's loaded-list twin must reach the same verdict, or the
      # dashboard and `mix kiln.audit.verify` disagree about the document.
      trail = KilnCMS.Governance.trail("page", page.id, page.org_id)
      assert {:tampered, ^reason} = trail.chain
    end

    # The compatibility guarantee: an anchor minted before #713 recorded no
    # attribution, so it must not be attribution-checked — it keeps verifying,
    # and a rewrite of an author it never attested is (honestly) not caught.
    # Unsigned so nulling the column doesn't also break a signature — which is
    # exactly what would catch the tamper on a keyed deployment.
    test "an anchor with no recorded attribution is not attribution-checked" do
      unsign!()
      actor = admin()
      other = admin()
      page = published_page(actor)

      KilnCMS.Repo.update_all(
        from(a in "history_anchors", where: a.source_id == type(^page.id, :binary_id)),
        set: [attribution_hash: nil]
      )

      # Still verifies (as an unsigned anchor did before this change)…
      assert :unsigned = Chain.verify(Page, "page", page.id, page.org_id)

      # …and the un-attested author can be rewritten without a tamper verdict.
      rewrite_author!(page, other.id)
      assert :unsigned = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # Attribution is folded incrementally in `mint` (seeded from the
    # predecessor's `attribution_hash`) but from genesis in `verify` — so a
    # chain of several v5 anchors is where the two must agree, and where a
    # rewrite must still be caught.
    test "attribution holds, and catches a rewrite, across a multi-anchor v5 chain" do
      actor = admin()
      other = admin()

      page = published_page(actor)
      page = CMS.update_page!(page, %{title: "Second"}, actor: actor)
      :ok = Chain.anchor(page)
      page = CMS.update_page!(page, %{title: "Third"}, actor: actor)
      :ok = Chain.anchor(page)

      assert length(Chain.anchors("page", page.id, page.org_id)) == 3
      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)

      rewrite_author!(page, other.id)
      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "author attribution"
    end

    # The action type is folded into attribution alongside the author, so
    # rewriting it is caught the same way — the other half of the digest.
    test "rewriting a version's action type is caught" do
      actor = admin()
      page = published_page(actor)

      KilnCMS.Repo.update_all(
        from(v in "pages_versions",
          where:
            v.version_source_id == type(^page.id, :binary_id) and
              v.version_action_type == "create"
        ),
        set: [version_action_type: "update"]
      )

      assert {:tampered, reason} = Chain.verify(Page, "page", page.id, page.org_id)
      assert reason =~ "author attribution"
    end

    # The compatibility guarantee for a SIGNED legacy anchor: re-sign this
    # anchor's own values under the pre-#713 `v: 4` payload shape and drop the
    # attribution column — exactly what an anchor minted by an earlier release
    # is — and it must still read `:verified`. Exercises the `[v4, v3]` signature
    # candidates that a nil-attribution anchor still falls through to.
    test "a signed anchor minted before #713 still verifies" do
      actor = admin()
      page = published_page(actor)
      [anchor] = Chain.anchors("page", page.id, page.org_id)

      v4_payload =
        Canonical.encode(%{
          "v" => 4,
          "type" => "page",
          "source_id" => page.id,
          "chain_hash" => anchor.chain_hash,
          "version_count" => anchor.version_count,
          "prev_anchor_id" => anchor.prev_anchor_id,
          "prev_anchor_digest" => anchor.prev_anchor_digest,
          "last_version_id" => anchor.last_version_id,
          "last_version_at" =>
            anchor.last_version_at && DateTime.to_iso8601(anchor.last_version_at),
          "sequence" => anchor.sequence
        })

      {:ok, v4_signature} = Signer.sign(v4_payload)

      KilnCMS.Repo.update_all(
        from(a in "history_anchors", where: a.id == type(^anchor.id, :binary_id)),
        set: [signature: v4_signature, attribution_hash: nil, payload_version: nil]
      )

      assert :verified = Chain.verify(Page, "page", page.id, page.org_id)
    end

    # Rewriting the author AND the anchor's recorded hash to match is caught by
    # the signature on a keyed deployment: `attribution_hash` is inside the v5
    # signed payload, so the doctored column no longer verifies under the key.
    test "rewriting the attribution_hash column to match is caught by the signature" do
      actor = admin()
      other = admin()
      page = published_page(actor)

      rewrite_author!(page, other.id)
      forged = Chain.compute(Page, page.id, page.org_id).attribution_hash

      KilnCMS.Repo.update_all(
        from(a in "history_anchors", where: a.source_id == type(^page.id, :binary_id)),
        set: [attribution_hash: forged]
      )

      # The attribution now reproduces, but the signature was over the ORIGINAL
      # attribution_hash — so the anchor no longer verifies under the held key.
      assert {:tampered, _} = Chain.verify(Page, "page", page.id, page.org_id)
    end
  end
end
