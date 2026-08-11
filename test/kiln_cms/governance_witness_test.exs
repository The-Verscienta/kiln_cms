defmodule KilnCMS.Governance.WitnessTest do
  @moduledoc """
  Publishing governance checkpoints outside the database (#666), and the audit
  comparison that is what actually makes publication worth anything.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  alias KilnCMS.CMS
  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.Governance.Witness

  setup do
    pem = KilnCMS.Keys.generate_rsa_pem()
    var = "KILN_TEST_WITNESS_#{System.unique_integer([:positive])}"
    System.put_env(var, pem)
    prev_provenance = Application.get_env(:kiln_cms, KilnCMS.Provenance)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Provenance,
      Keyword.merge(prev_provenance || [], signing_key: {:env, %{"var" => var}})
    )

    dir = Path.join(System.tmp_dir!(), "kiln-witness-#{System.unique_integer([:positive])}")
    prev_witness = Application.get_env(:kiln_cms, Witness)

    Application.put_env(:kiln_cms, Witness, adapter: Witness.File)
    Application.put_env(:kiln_cms, Witness.File, dir: dir)

    on_exit(fn ->
      if prev_provenance,
        do: Application.put_env(:kiln_cms, KilnCMS.Provenance, prev_provenance)

      System.delete_env(var)

      if prev_witness,
        do: Application.put_env(:kiln_cms, Witness, prev_witness),
        else: Application.delete_env(:kiln_cms, Witness)

      Application.delete_env(:kiln_cms, Witness.File)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "witness-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    actor = admin()

    page =
      CMS.create_page!(
        %{title: "Witnessed", slug: "witness-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.publish_page!(page, %{}, actor: actor)
  end

  describe "the file adapter" do
    test "publishes a checkpoint and records the receipt", %{dir: dir} do
      page = published_page()
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      refute is_nil(checkpoint.witnessed_at)
      assert checkpoint.witness == "file"
      assert %{"path" => path, "sha256" => digest} = checkpoint.witness_receipt
      assert String.starts_with?(path, Path.expand(dir))
      assert File.exists?(path)

      body = File.read!(path)
      assert Base.encode16(:crypto.hash(:sha256, body), case: :lower) == digest
      assert body == Checkpoint.document(checkpoint, page.org_id)
    end

    # The one property the sink has to have. A witness that accepts an overwrite
    # lets an attacker who can write it rewrite history, which is worse than no
    # witness because it looks intact.
    test "refuses to overwrite an existing key" do
      page = published_page()
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      key = Witness.key(page.org_id, checkpoint.sequence)

      assert {:error, :already_published} = Witness.publish(key, "different bytes")
    end

    test "the published document is self-contained and re-verifies offline" do
      page = published_page()
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      {:ok, body} = Witness.fetch(Witness.key(page.org_id, checkpoint.sequence))
      decoded = Jason.decode!(body)

      assert decoded["kiln_checkpoint"] == 1
      assert decoded["root"] == checkpoint.root
      assert decoded["org_id"] == page.org_id
      assert [entry] = decoded["entries"]
      assert entry["source_id"] == page.id
      assert entry["head_sequence"] == 1

      # The proof travels with the entry, so a holder of the file and the public
      # key needs nothing from the database.
      leaf =
        KilnCMS.Governance.Merkle.leaf(Map.delete(entry, "proof"))

      assert KilnCMS.Governance.Merkle.verify(leaf, entry["proof"], decoded["root"])
    end

    # A key that escapes the configured directory turns the read-only audit path
    # into an arbitrary file read, and the key is chosen by a database column.
    test "refuses a key that escapes the witness directory" do
      assert {:error, :invalid_witness_key} = Witness.publish("../escape.json", "x")
      assert {:error, :invalid_witness_key} = Witness.fetch("../../etc/passwd")
    end

    test "an unconfigured directory is an error, not a crash" do
      Application.put_env(:kiln_cms, Witness.File, [])

      assert {:error, :witness_dir_not_configured} = Witness.publish("a/b.json", "x")
      assert {:error, :witness_dir_not_configured} = Witness.fetch("a/b.json")
    end

    # A relative dir resolves against the cwd, and the release that publishes and
    # the host that audits deliberately run from different places — the symptom
    # would be every checkpoint reported MISSING.
    test "a relative directory is refused rather than silently resolved" do
      Application.put_env(:kiln_cms, Witness.File, dir: "governance")

      assert {:error, :witness_dir_not_absolute} = Witness.publish("a/b.json", "x")
      assert {:error, :witness_dir_not_absolute} = Witness.fetch("a/b.json")
    end
  end

  describe "publication is confirmed by reading back" do
    # `:already_published` means AN object is at that key, not THIS one. After a
    # rolled-back checkpoint table the re-mint lands on a sequence the sink
    # already holds with different contents — the fingerprint of the attack —
    # and that must never be recorded as a green receipt.
    test "a sink holding different bytes at the key is an error, not a receipt" do
      page = published_page()

      # Occupy the key the next checkpoint will claim.
      :ok =
        case Witness.publish(Witness.key(page.org_id, 1), "someone else's checkpoint") do
          {:ok, _receipt} -> :ok
          other -> other
        end

      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      assert is_nil(checkpoint.witnessed_at)
      assert checkpoint.witness_error =~ "already holds a DIFFERENT document"
    end
  end

  describe "publication failures" do
    test "a checkpoint whose publication failed is still minted, and retried" do
      Application.put_env(:kiln_cms, Witness.File, [])

      page = published_page()
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      # The commitment landed; only the publication did not.
      assert is_nil(checkpoint.witnessed_at)
      assert checkpoint.witness_error =~ "witness_dir_not_configured"
      assert [checkpoint.id] == Enum.map(Checkpoint.unwitnessed(page.org_id), & &1.id)
    end

    test "the retry publishes an earlier checkpoint once the sink works", %{dir: dir} do
      Application.put_env(:kiln_cms, Witness.File, [])
      page = published_page()
      {:ok, first} = Checkpoint.mint(page.org_id)
      assert is_nil(first.witnessed_at)

      Application.put_env(:kiln_cms, Witness.File, dir: dir)
      KilnCMS.Governance.CheckpointWorker.run_for_org(page.org_id)

      assert Checkpoint.unwitnessed(page.org_id) == []
      assert {:ok, _body} = Witness.fetch(Witness.key(page.org_id, first.sequence))
    end
  end

  describe "the audit comparison" do
    # The signature covers `covered_at` as an ISO-8601 string, so the document a
    # DB-loaded checkpoint re-derives has to be byte-identical to the one that
    # was published from the in-memory struct. Any precision drift on the
    # timestamp column would make every audit a false alarm and every signature
    # unverifiable — asserted rather than assumed.
    test "a reloaded checkpoint re-derives the published bytes and still verifies" do
      page = published_page()
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      {:ok, published} = Witness.fetch(Witness.key(page.org_id, checkpoint.sequence))

      reloaded = Checkpoint.latest(page.org_id)
      assert reloaded.id == checkpoint.id
      assert Checkpoint.document(reloaded, page.org_id) == published
      assert :ok = Checkpoint.checkpoint_attestation(reloaded, page.org_id)
    end

    test "a checkpoint row rewritten after publication no longer matches the sink" do
      page = published_page()
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      {:ok, published} = Witness.fetch(Witness.key(page.org_id, checkpoint.sequence))

      KilnCMS.Repo.update_all(
        from(c in "chain_checkpoints",
          where: c.id == type(^checkpoint.id, :binary_id),
          update: [set: [document_count: 0]]
        ),
        []
      )

      reloaded = Checkpoint.latest(page.org_id)
      refute published == Checkpoint.document(reloaded, page.org_id)
    end

    # The direction that matters. Walking database rows can only find an object
    # that is missing or altered; a DELETED row is never looked up. Enumerating
    # the sink is what makes a truncated checkpoint table visible at all.
    test "the sink can be listed, so a deleted checkpoint row is discoverable" do
      page = published_page()
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      assert {:ok, keys} = Witness.list(page.org_id)
      assert keys == [Witness.key(page.org_id, checkpoint.sequence)]
      assert Witness.sequence_from_key(hd(keys)) == checkpoint.sequence

      KilnCMS.Repo.delete_all(
        from(e in "chain_checkpoint_entries",
          where: e.checkpoint_id == type(^checkpoint.id, :binary_id)
        )
      )

      KilnCMS.Repo.delete_all(
        from(c in "chain_checkpoints", where: c.id == type(^checkpoint.id, :binary_id))
      )

      assert Checkpoint.recent(page.org_id) == []
      # The sink still holds it — which is the discrepancy.
      assert {:ok, [_key]} = Witness.list(page.org_id)
    end

    test "listing an org that has published nothing is empty, not an error" do
      assert {:ok, []} = Witness.list(Ecto.UUID.generate())
    end
  end

  # #732. Each row signs its predecessor's id AND a digest of its contents, but
  # nothing walked the run: `Chain.verify/4` attests only the checkpoint an entry
  # names, and the audit's contiguity check reads sequence numbers, not links.
  # So a checkpoint rewritten in place was caught only by its own signature
  # failing — which on an unsigned deployment it does not.
  describe "predecessor links across the run (#732)" do
    # Hand-built rows rather than minted ones: the point is to express runs a
    # correct mint can never produce, which is exactly what an attacker writes.
    defp link(sequence, attrs) do
      base = %{
        id: Ecto.UUID.generate(),
        sequence: sequence,
        root: "root-#{sequence}",
        document_count: sequence,
        signature: nil,
        prev_checkpoint_id: nil,
        prev_checkpoint_digest: nil
      }

      Map.merge(base, attrs)
    end

    # A well-formed run of `n` checkpoints, newest first — the shape
    # `Checkpoint.recent/1` returns.
    defp run(n) do
      Enum.reduce(1..n, [], fn sequence, acc ->
        prev = List.first(acc)

        [
          link(sequence, %{
            prev_checkpoint_id: prev && prev.id,
            prev_checkpoint_digest: Checkpoint.digest(prev)
          })
          | acc
        ]
      end)
    end

    test "a well-formed run has no broken links" do
      assert Checkpoint.link_failures(run(4)) == []
    end

    test "a single genesis checkpoint is a clean run" do
      assert Checkpoint.link_failures(run(1)) == []
      assert Checkpoint.link_failures([]) == []
    end

    test "a predecessor rewritten in place is caught, with no signature involved" do
      # THE case the issue is about. Sequence 2's contents change; its number and
      # every link id stay put, so contiguity is satisfied and nothing is signed.
      [four, three, two, one] = run(4)
      rewritten = %{two | document_count: 999}

      failures = Checkpoint.link_failures([four, three, rewritten, one])

      assert [message] = failures
      assert message =~ "checkpoint 3 does not match the contents of predecessor 2"
      assert message =~ "rewritten"
    end

    test "an excised middle checkpoint leaves its successor's link dangling" do
      [four, three, _two, one] = run(4)

      assert [message] = Checkpoint.link_failures([four, three, one])
      assert message =~ "checkpoint 3 names predecessor"
      assert message =~ "no longer exists"
    end

    test "detaching a row by nulling its link is caught, not skipped" do
      # The cheapest single-column edit, and the one a walk that rejects null
      # links before comparing digests would step straight over.
      [four, three, two, one] = run(4)
      detached = %{three | prev_checkpoint_id: nil, prev_checkpoint_digest: nil}

      [first | _rest] = Checkpoint.link_failures([four, detached, two, one])
      assert first =~ "checkpoint 3 names no predecessor"
    end

    test "an edit cascades to the successor, because the link columns are inside the digest" do
      # `digest/1` covers `prev_checkpoint_id`/`prev_checkpoint_digest`, so any
      # edit to a row's link also changes what its successor should have
      # recorded. Two reports for one edit is correct and worth knowing about:
      # an operator reading the audit sees the detached row AND the row that
      # noticed, not a single ambiguous line.
      [four, three, two, one] = run(4)
      detached = %{three | prev_checkpoint_id: nil, prev_checkpoint_digest: nil}

      assert [detach, cascade] = Checkpoint.link_failures([four, detached, two, one])
      assert detach =~ "checkpoint 3 names no predecessor"
      assert cascade =~ "checkpoint 4 does not match the contents of predecessor 3"
    end

    test "a link that jumps back over a surviving checkpoint is caught" do
      # Contiguity cannot see this — 1..4 are all present. Only the links show
      # that 3 has been threaded out of the run.
      [four, three, two, one] = run(4)

      rethreaded = %{
        four
        | prev_checkpoint_id: two.id,
          prev_checkpoint_digest: Checkpoint.digest(two)
      }

      assert [message] = Checkpoint.link_failures([rethreaded, three, two, one])
      assert message =~ "checkpoint 4 links back to 2"
      assert message =~ "skipping 3"
    end

    test "a genesis checkpoint that names a predecessor is caught" do
      [two, one] = run(2)
      rerooted = %{one | prev_checkpoint_id: Ecto.UUID.generate()}

      [first | _cascade] = Checkpoint.link_failures([two, rerooted])
      assert first =~ "checkpoint 1 is the first in the run but names predecessor"
    end

    test "failures are reported oldest first, so the earliest edit reads first" do
      [four, three, two, one] = run(4)
      detached_two = %{two | prev_checkpoint_id: nil, prev_checkpoint_digest: nil}
      detached_four = %{four | prev_checkpoint_id: nil, prev_checkpoint_digest: nil}

      failures = Checkpoint.link_failures([detached_four, three, detached_two, one])

      # `recent/1` hands them over newest first; an audit reads better in the
      # order the edits happened.
      reported =
        Enum.map(failures, fn message ->
          [_, sequence] = Regex.run(~r/checkpoint (\d+)/, message)
          String.to_integer(sequence)
        end)

      assert reported == Enum.sort(reported)
      assert List.first(reported) == 2
    end

    # The honest limit, asserted so nobody reads the walk as covering more than
    # it does — this is what the witness and the sink enumeration are for.
    test "a clean truncation of the newest checkpoints has intact links throughout" do
      [_five, _four, three, two, one] = run(5)

      assert Checkpoint.link_failures([three, two, one]) == []
    end

    test "a genesis checkpoint with a stray predecessor digest is caught" do
      [two, one] = run(2)
      stray = %{one | prev_checkpoint_digest: "not-nil"}

      [first | _cascade] = Checkpoint.link_failures([two, stray])
      assert first =~ "checkpoint 1 is the first in the run but records a predecessor digest"
    end

    test "a forward link says so, rather than claiming something was skipped" do
      # `prev_n >= n` skips nothing. The "skipping N" wording would send an
      # operator hunting a deletion that never happened.
      [three, two, one] = run(3)

      forward = %{
        two
        | prev_checkpoint_id: three.id,
          prev_checkpoint_digest: Checkpoint.digest(three)
      }

      [message | _] = Checkpoint.link_failures([three, forward, one])
      assert message =~ "which is not earlier than it"
      refute message =~ "skipping"
    end

    # The limits, asserted so neither the moduledoc nor this suite can be read as
    # promising more than the walk delivers.
    test "a rewrite of the HEAD checkpoint is invisible — nothing records its digest" do
      [four, three, two, one] = run(4)
      doctored_head = %{four | root: "rewritten", document_count: 9_999}

      assert Checkpoint.link_failures([doctored_head, three, two, one]) == []
    end

    test "an attacker who cascades the digests forward walks clean" do
      # `digest/1` is an unkeyed hash over public columns, so rewriting a row and
      # recomputing every link after it costs one UPDATE per downstream row. What
      # this buys is not detection but amplification: `prev_checkpoint_digest` is
      # inside `document/2`, so the cascade forces a rewrite of every PUBLISHED
      # object too, turning one witness mismatch into many.
      [_four, _three, _two, one] = run(4)
      doctored = %{one | root: "rewritten"}

      cascaded =
        Enum.reduce(2..4, [doctored], fn sequence, acc ->
          prev = List.first(acc)

          [
            link(sequence, %{
              prev_checkpoint_id: prev.id,
              prev_checkpoint_digest: Checkpoint.digest(prev)
            })
            | acc
          ]
        end)

      assert Checkpoint.link_failures(cascaded) == []
    end

    test "covered_at and key_id are now covered by the digest (#892)" do
      # Pre-#892 (digest v1) neither was hashed, so an edit to either was
      # invisible to this walk — only the witness comparison caught them. v2
      # closes that; `signature` was already covered under v1 and stays a
      # contrast case.
      [two, one] = run(2)

      assert Checkpoint.digest(%{one | signature: "forged"}) != Checkpoint.digest(one)

      edited_covered_at = Map.put(one, :covered_at, ~U[2030-01-01 00:00:00Z])
      assert [message] = Checkpoint.link_failures([two, edited_covered_at])
      assert message =~ "checkpoint 2 does not match the contents of predecessor 1"

      edited_key_id = Map.put(one, :key_id, "bogus")
      assert [message] = Checkpoint.link_failures([two, edited_key_id])
      assert message =~ "checkpoint 2 does not match the contents of predecessor 1"
    end

    # #892: widening the digest could not be a one-line edit, because its
    # output is already embedded in every existing `prev_checkpoint_digest` —
    # so a link minted under the old (v1) shape must keep verifying under the
    # new code, rather than the whole prior history reporting as tampered.
    test "a link minted under the old digest shape still verifies after the widening" do
      one =
        link(1, %{
          # Real values, unlike `run/1`'s fixtures — the case worth pinning is
          # a v1 link whose predecessor genuinely HAS the columns v2 covers,
          # not one where both versions happen to hash the same nil.
          covered_at: ~U[2026-01-01 00:00:00.000000Z],
          key_id: "kiln-key-1"
        })

      # Simulates a row written before #892 shipped: its successor's recorded
      # digest is the OLD shape, which never covered covered_at/key_id.
      two =
        link(2, %{
          prev_checkpoint_id: one.id,
          prev_checkpoint_digest: Checkpoint.digest(one, 1)
        })

      assert Checkpoint.link_failures([two, one]) == []
    end

    test "a run mixing an old (v1) link with a freshly-minted (v2) one still walks clean" do
      one = link(1, %{covered_at: ~U[2026-01-01 00:00:00.000000Z], key_id: "kiln-key-1"})

      two =
        link(2, %{prev_checkpoint_id: one.id, prev_checkpoint_digest: Checkpoint.digest(one, 1)})

      # `three` is minted "now" — `Checkpoint.digest/1` defaults to the newest
      # version, exactly as `mint/1` does.
      three =
        link(3, %{prev_checkpoint_id: two.id, prev_checkpoint_digest: Checkpoint.digest(two)})

      assert Checkpoint.link_failures([three, two, one]) == []
    end

    test "a real minted run walks clean" do
      # Guards `mint/1` against writing the links in a shape the walk rejects,
      # and `recent/1` against returning one it can't read. It does NOT guard the
      # fixtures against a digest-shape drift — both sides call the same
      # `digest/1`, so a shape change moves them together.
      page = published_page()
      {:ok, _first} = Checkpoint.mint(page.org_id)

      _page2 = published_page()
      {:ok, _second} = Checkpoint.mint(page.org_id)

      rows = Checkpoint.recent(page.org_id)
      assert length(rows) == 2
      assert Checkpoint.link_failures(rows) == []
    end
  end

  describe "the none adapter" do
    test "mints without publishing and says so" do
      Application.put_env(:kiln_cms, Witness, adapter: Witness.None)

      page = published_page()
      {:ok, checkpoint} = Checkpoint.mint(page.org_id)

      assert checkpoint.witness == "none"
      assert is_nil(checkpoint.witnessed_at)
      # Not an error: the operator chose this, so it is not reported as a
      # failure the next run should retry.
      assert is_nil(checkpoint.witness_error)
      refute Witness.enabled?()
    end
  end
end
