defmodule KilnCMS.CMS.PromotionAnchorsTest do
  @moduledoc """
  Promotion re-attests a document's tamper-evident history anchors under the
  compiled type (#704). `:page` stands in as the compiled target, as in
  `KilnCMS.CMS.PromotionTest`. `async: false` because the signing key lives in
  application env, which these tests toggle.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Entry
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Promotion
  alias KilnCMS.Governance.Chain
  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.Repo

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "promo-anchor-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define_type!(actor) do
    CMS.create_type_definition!(
      %{name: "pra#{System.unique_integer([:positive])}", label: "Promotable"},
      actor: actor
    )
  end

  defp slug, do: "pra-#{System.unique_integer([:positive])}"

  # Configure a real provenance signing key for the duration of one test, so
  # anchors are signed and can reach `:verified`. Mirrors the chain test's setup.
  defp enable_signing! do
    pem = KilnCMS.Keys.generate_rsa_pem()
    var = "KILN_TEST_PROMO_ANCHOR_#{System.unique_integer([:positive])}"
    System.put_env(var, pem)
    prev = Application.get_env(:kiln_cms, KilnCMS.Provenance)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Provenance,
      Keyword.merge(prev || [], signing_key: {:env, %{"var" => var}})
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:kiln_cms, KilnCMS.Provenance, prev),
        else: Application.delete_env(:kiln_cms, KilnCMS.Provenance)

      System.delete_env(var)
    end)

    var
  end

  # A dynamic entry with `count` anchors under the "entry" storage key.
  defp anchored_entry(actor, definition, count) do
    entry = ContentTypes.create!(definition.name, %{title: "v0", slug: slug()}, actor: actor)

    Enum.reduce(1..count, entry, fn n, acc ->
      {:ok, acc} = CMS.update_entry(acc, %{title: "v#{n}"}, actor: actor)
      :ok = Chain.anchor(acc)
      acc
    end)
  end

  test "a promoted document's signed anchor chain is re-attested under the compiled type" do
    enable_signing!()
    actor = admin()
    definition = define_type!(actor)

    # Three anchors so the re-signed chain has to re-propagate its digest links.
    entry = anchored_entry(actor, definition, 3)

    entry_sequences = Chain.anchors("entry", entry.id, entry.org_id) |> Enum.map(& &1.sequence)
    assert entry_sequences == [3, 2, 1]
    assert :verified = Chain.verify(Entry, "entry", entry.id, entry.org_id)

    assert {:ok, %{entries: 1}} = Promotion.promote!(definition.name, into: :page)

    # The chain moved with the document: it verifies under the compiled type and
    # no longer answers under the abandoned "entry" key.
    assert :verified = Chain.verify(Page, "page", entry.id, entry.org_id)

    page_sequences = Chain.anchors("page", entry.id, entry.org_id) |> Enum.map(& &1.sequence)
    assert page_sequences == [3, 2, 1]
    assert Chain.anchors("entry", entry.id, entry.org_id) == []
  end

  test "without a signing key the promoted chain is repointed and still checks integrity" do
    # No `enable_signing!` — the deployment has no key, so anchors are unsigned.
    actor = admin()
    definition = define_type!(actor)
    entry = anchored_entry(actor, definition, 2)

    assert :unsigned = Chain.verify(Entry, "entry", entry.id, entry.org_id)

    assert {:ok, %{entries: 1}} = Promotion.promote!(definition.name, into: :page)

    # Repointed and structurally intact — `:unsigned`, not orphaned to `:unanchored`.
    assert :unsigned = Chain.verify(Page, "page", entry.id, entry.org_id)
    assert Chain.anchors("entry", entry.id, entry.org_id) == []
    assert [_ | _] = Chain.anchors("page", entry.id, entry.org_id)
  end

  test "a mixed signed/unsigned chain keeps its :unsigned verdict — promotion never upgrades it" do
    enable_signing!()
    actor = admin()
    definition = define_type!(actor)

    entry = ContentTypes.create!(definition.name, %{title: "v0", slug: slug()}, actor: actor)
    {:ok, entry} = CMS.update_entry(entry, %{title: "v1"}, actor: actor)
    :ok = Chain.anchor(entry)

    # One anchor minted while the key is unavailable → stored unsigned. Toggling
    # only the config (not the env var) leaves the SAME key in place, so the
    # anchors on either side stay verifiable — the middle one is simply unsigned.
    # This is the anchor promotion must NOT silently re-sign into attestation.
    keyed = Application.get_env(:kiln_cms, KilnCMS.Provenance)
    Application.put_env(:kiln_cms, KilnCMS.Provenance, Keyword.delete(keyed, :signing_key))
    {:ok, entry} = CMS.update_entry(entry, %{title: "v2"}, actor: actor)
    :ok = Chain.anchor(entry)
    Application.put_env(:kiln_cms, KilnCMS.Provenance, keyed)

    {:ok, entry} = CMS.update_entry(entry, %{title: "v3"}, actor: actor)
    :ok = Chain.anchor(entry)

    # A single unsigned anchor floors the whole chain to :unsigned.
    assert :unsigned = Chain.verify(Entry, "entry", entry.id, entry.org_id)

    assert {:ok, %{entries: 1}} = Promotion.promote!(definition.name, into: :page)

    # Byte-for-byte the chain a native compiled document would carry: still
    # :unsigned, NOT upgraded to :verified by re-keying the advisory anchor.
    assert :unsigned = Chain.verify(Page, "page", entry.id, entry.org_id)
  end

  test "re-attests every promoted document in one run (entries: 2)" do
    enable_signing!()
    actor = admin()
    definition = define_type!(actor)

    one = anchored_entry(actor, definition, 2)
    two = anchored_entry(actor, definition, 1)

    assert :verified = Chain.verify(Entry, "entry", one.id, one.org_id)
    assert :verified = Chain.verify(Entry, "entry", two.id, two.org_id)

    assert {:ok, %{entries: 2}} = Promotion.promote!(definition.name, into: :page)

    assert :verified = Chain.verify(Page, "page", one.id, one.org_id)
    assert :verified = Chain.verify(Page, "page", two.id, two.org_id)
    assert Chain.anchors("entry", one.id, one.org_id) == []
    assert Chain.anchors("entry", two.id, two.org_id) == []
  end

  # Doctor the earliest version row's `changes`, which every anchor folds.
  defp doctor_a_version!(entry) do
    [version | _] =
      CMS.list_entry_versions!(
        authorize?: false,
        query: [filter: [version_source_id: entry.id], sort: [version_inserted_at: :asc]]
      )

    Repo.query!(
      "UPDATE entries_versions SET changes = changes || '{\"laundered\": true}'::jsonb WHERE id = $1",
      [Ecto.UUID.dump!(version.id)]
    )
  end

  test "promotion refuses a chain whose versions were doctored (hash no longer reproduces)" do
    enable_signing!()
    actor = admin()
    definition = define_type!(actor)
    entry = anchored_entry(actor, definition, 2)

    doctor_a_version!(entry)
    assert {:tampered, _} = Chain.verify(Entry, "entry", entry.id, entry.org_id)

    assert_raise RuntimeError, ~r/cannot be re-attested/, fn ->
      Promotion.promote!(definition.name, into: :page)
    end

    # Rolled back — still a live, "entry"-anchored dynamic document.
    assert [_ | _] = ContentTypes.list!(definition.name, actor: actor)
    assert [_ | _] = Chain.anchors("entry", entry.id, entry.org_id)
  end

  test "promotion refuses to launder a doctored chain even when its hash was updated to match" do
    enable_signing!()
    actor = admin()
    definition = define_type!(actor)
    entry = anchored_entry(actor, definition, 1)

    # The attacker's move WITHOUT the signing key: rewrite a version AND update
    # every anchor's chain_hash to the recomputed (doctored) fold, so the hash
    # reproduces and only the original signature — which they cannot forge —
    # still betrays the tamper. `verify` reads :tampered solely on the signature.
    doctor_a_version!(entry)

    for anchor <- Chain.anchors("entry", entry.id, entry.org_id) do
      doctored = Chain.compute(Entry, entry.id, entry.org_id, anchor.version_count).chain_hash

      Repo.query!("UPDATE history_anchors SET chain_hash = $1 WHERE id = $2", [
        doctored,
        Ecto.UUID.dump!(anchor.id)
      ])
    end

    assert {:tampered, _} = Chain.verify(Entry, "entry", entry.id, entry.org_id)

    # Re-signing over the doctored-but-reproducing hash would mint a valid
    # current-key signature and flip it to :verified. The signature pre-check
    # refuses instead.
    assert_raise RuntimeError, ~r/existing signature does not verify/, fn ->
      Promotion.promote!(definition.name, into: :page)
    end

    assert [_ | _] = ContentTypes.list!(definition.name, actor: actor)
  end

  test "a signed chain with no key available aborts the promotion rather than breaking signatures" do
    var = enable_signing!()
    actor = admin()
    definition = define_type!(actor)
    entry = anchored_entry(actor, definition, 2)

    # Drop the key AFTER the anchors are signed: now they cannot be re-signed.
    prev = Application.get_env(:kiln_cms, KilnCMS.Provenance)
    Application.put_env(:kiln_cms, KilnCMS.Provenance, Keyword.delete(prev, :signing_key))
    System.delete_env(var)

    assert_raise RuntimeError, ~r/without the provenance signing key/, fn ->
      Promotion.promote!(definition.name, into: :page)
    end

    # The whole move rolled back: the document is still a live entry, still
    # anchored under "entry", nothing orphaned.
    assert [_ | _] = ContentTypes.list!(definition.name, actor: actor)
    assert [_ | _] = Chain.anchors("entry", entry.id, entry.org_id)
    assert ContentTypes.get_dynamic(definition.name)
  end

  # #849. Re-attesting moves the anchors to a `resource_type` no checkpoint
  # entry mentions, and `Checkpoint.witnessed_head/3` reads entries by
  # `{resource_type, source_id}` — so without a mint at promotion time the
  # document is unwitnessed until the next scheduled checkpoint, and a
  # truncation of its newest anchors inside that window goes uncaught.
  describe "checkpoint coverage across promotion (#849)" do
    test "the promoted document is witnessed under its new type immediately" do
      actor = admin()
      definition = define_type!(actor)
      entry = anchored_entry(actor, definition, 2)

      # Covered under the old type before the move, so the assertion below is
      # about the move rather than about checkpointing being on at all.
      {:ok, _} = Checkpoint.mint(entry.org_id)

      assert {:ok, %{resource_type: "entry"}, _} =
               Checkpoint.witnessed_head("entry", entry.id, entry.org_id)

      assert {:ok, %{entries: 1}} = Promotion.promote!(definition.name, into: :page)

      assert {:ok, %{resource_type: "page"} = head, attestation} =
               Checkpoint.witnessed_head("page", entry.id, entry.org_id)

      # The entry attests the chain's real head, not a stale one.
      assert head.head_sequence == 2
      # `{:tampered, _}` is a valid third shape here and must not read as ok.
      assert attestation in [:ok, :unsigned, :unverifiable]
    end

    test "the old 'entry' checkpoint entries are left exactly as they were" do
      actor = admin()
      definition = define_type!(actor)
      entry = anchored_entry(actor, definition, 2)

      {:ok, _} = Checkpoint.mint(entry.org_id)

      before =
        CMS.list_checkpoint_entries_for!("entry", entry.id,
          authorize?: false,
          tenant: entry.org_id
        )

      assert [_ | _] = before

      assert {:ok, %{entries: 1}} = Promotion.promote!(definition.name, into: :page)

      # Their Merkle leaves commit to `resource_type`, so re-keying them would
      # invalidate every stored proof against its published root — and they are
      # a true record of what that chain's head was under the old type.
      # Superseding history is not the same as rewriting it.
      after_promotion =
        CMS.list_checkpoint_entries_for!("entry", entry.id,
          authorize?: false,
          tenant: entry.org_id
        )

      assert Enum.map(after_promotion, & &1.id) == Enum.map(before, & &1.id)

      assert Enum.map(after_promotion, &{&1.resource_type, &1.chain_hash, &1.proof}) ==
               Enum.map(before, &{&1.resource_type, &1.chain_hash, &1.proof})
    end

    test "a promotion that re-attests nothing mints no checkpoint" do
      actor = admin()
      definition = define_type!(actor)
      # A document with no anchors at all: nothing to re-attest, so nothing to
      # re-witness, and an extra checkpoint row per promotion would be noise in
      # the sequence the link walk verifies.
      doc =
        ContentTypes.create!(definition.name, %{title: "unanchored", slug: slug()}, actor: actor)

      # Read the org off the document, not from `default_org_id/0`: the code
      # mints for `definition.org_id`, and the two coincide only while type
      # definitions land in the default org. Watching the wrong one would make
      # this assertion unable to fail.
      org_id = doc.org_id

      # Pinned rather than inherited from `:audit_anchor_every_write` being off
      # by default — with it on, the create anchors and this stops testing zero.
      assert Chain.anchors("entry", doc.id, org_id) == []

      {:ok, baseline} = Checkpoint.mint(org_id)

      assert {:ok, %{entries: 1}} = Promotion.promote!(definition.name, into: :page)

      assert Checkpoint.latest(org_id).sequence == baseline.sequence
    end

    # The mint runs after the transaction committed, so it must never turn a
    # succeeded promotion into a raised failure. `mint/1` raises on paths
    # `{:error, _}` never reaches — a `Repo.query` match, a `create_…!` bang,
    # and `ExAws.request()` inside the S3 witness on bad adapter config — which
    # is why `CheckpointWorker` rescues the identical call. A broken witness
    # adapter stands in for all of them.
    test "a raising mint does not fail a promotion that already committed" do
      actor = admin()
      definition = define_type!(actor)
      entry = anchored_entry(actor, definition, 1)

      previous = Application.get_env(:kiln_cms, KilnCMS.Governance.Witness)

      Application.put_env(:kiln_cms, KilnCMS.Governance.Witness,
        adapter: __MODULE__.NoSuchAdapter,
        enabled: true
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, KilnCMS.Governance.Witness, previous),
          else: Application.delete_env(:kiln_cms, KilnCMS.Governance.Witness)
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{entries: 1}} = Promotion.promote!(definition.name, into: :page)
        end)

      # The data move stands, and the operator is told what they lost and how
      # to get it back — not pointed at `mix kiln.audit.checkpoint`, which never
      # walks checkpoint entries and would report green.
      assert Chain.anchors("page", entry.id, entry.org_id) != []
      assert log =~ "The promotion itself committed"
      assert log =~ "CheckpointWorker.run_for_org/1"
      refute log =~ "kiln.audit.checkpoint"
    end
  end
end
