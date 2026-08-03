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
