defmodule Mix.Tasks.Kiln.Audit.CheckpointTest do
  @moduledoc """
  `mix kiln.audit.checkpoint` (#666) — the task an operator runs, from a machine
  that is not the application host, to find out whether the governance chain has
  been truncated.

  The task had no test. `governance_witness_test.exs` covers `compare/2` and the
  publishing; `Checkpoint.link_failures/1` is unit-tested against hand-built
  runs. What only this task decides is what an auditor is *told* and what the
  shell gets back — and the exit code is the whole point of a tool that "has to
  be trusted": a run that prints discrepancies and exits 0 would pass a cron job
  and a CI gate alike.

  The cases below are the three the moduledoc promises to make visible: a row
  deleted (the sink holds a checkpoint the database does not — what truncating
  a chain has to do first), a row rewritten, and a deployment with no witness at
  all, which is not "nothing to check" but an unaudited deployment.
  """
  use KilnCMS.DataCase, async: false

  import Ecto.Query

  alias KilnCMS.CMS
  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.Governance.Witness
  alias Mix.Tasks.Kiln.Audit.Checkpoint, as: Task

  setup do
    pem = KilnCMS.Keys.generate_rsa_pem()
    var = "KILN_TEST_CHECKPOINT_#{System.unique_integer([:positive])}"
    System.put_env(var, pem)
    previous_provenance = Application.get_env(:kiln_cms, KilnCMS.Provenance)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Provenance,
      Keyword.merge(previous_provenance || [], signing_key: {:env, %{"var" => var}})
    )

    dir = Path.join(System.tmp_dir!(), "kiln-checkpoint-#{System.unique_integer([:positive])}")
    previous_witness = Application.get_env(:kiln_cms, Witness)
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      System.delete_env(var)

      if previous_provenance,
        do: Application.put_env(:kiln_cms, KilnCMS.Provenance, previous_provenance)

      if previous_witness,
        do: Application.put_env(:kiln_cms, Witness, previous_witness),
        else: Application.delete_env(:kiln_cms, Witness)

      Application.delete_env(:kiln_cms, Witness.File)
      File.rm_rf(dir)
    end)

    %{dir: dir, org_id: KilnCMS.Accounts.default_org_id()}
  end

  defp with_witness(dir) do
    Application.put_env(:kiln_cms, Witness, adapter: Witness.File)
    Application.put_env(:kiln_cms, Witness.File, dir: dir)
  end

  defp without_witness do
    Application.put_env(:kiln_cms, Witness, adapter: Witness.None)
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "checkpoint-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page do
    actor = admin()

    page =
      CMS.create_page!(
        %{title: "Checkpointed", slug: "checkpoint-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.publish_page!(page, %{}, actor: actor)
  end

  defp output do
    collect([]) |> Enum.reverse() |> Enum.join("\n")
  end

  defp collect(acc) do
    receive do
      {:mix_shell, :info, [line]} -> collect([line | acc])
      {:mix_shell, :error, [line]} -> collect([line | acc])
    after
      0 -> acc
    end
  end

  # Excise a checkpoint the way anything truncating a chain would have to: its
  # entries carry a foreign key, and so does its successor's `prev_checkpoint_id`
  # — which is the point of that column. Both are cleared first, so what the
  # audit sees is the same as what a careless attacker would leave behind.
  defp excise!(checkpoint) do
    KilnCMS.Repo.delete_all(
      from(e in "chain_checkpoint_entries",
        where: e.checkpoint_id == type(^checkpoint.id, :binary_id)
      )
    )

    KilnCMS.Repo.update_all(
      from(c in "chain_checkpoints",
        where: c.prev_checkpoint_id == type(^checkpoint.id, :binary_id)
      ),
      set: [prev_checkpoint_id: nil]
    )

    KilnCMS.Repo.delete_all(
      from(c in "chain_checkpoints", where: c.id == type(^checkpoint.id, :binary_id))
    )
  end

  # The task exits non-zero on any discrepancy, which is the contract a cron job
  # or a CI gate reads.
  defp audit(args) do
    catch_exit(Task.run(["--audit" | args]))
  end

  describe "minting" do
    test "reports the checkpoint it minted, and where it went", %{dir: dir, org_id: org_id} do
      with_witness(dir)
      published_page()

      Task.run(["--org", org_id])
      out = output()

      assert out =~ "Witness: "
      assert out =~ ~r/#{org_id}: checkpoint 1 over \d+ document\(s\), root \w+… \[published\]/
      assert [%{sequence: 1}] = Checkpoint.recent(org_id)
    end

    test "says so when the checkpoint could not be published", %{org_id: org_id} do
      # A file witness with no directory configured: the row is minted, the
      # publication fails, and the line has to say which.
      Application.put_env(:kiln_cms, Witness, adapter: Witness.File)
      Application.put_env(:kiln_cms, Witness.File, [])
      published_page()

      Task.run(["--org", org_id])

      assert output() =~ "[NOT PUBLISHED:"
    end

    test "with no witness at all, the checkpoint is minted and marked unpublished", %{
      org_id: org_id
    } do
      without_witness()
      published_page()

      Task.run(["--org", org_id])

      assert output() =~ "[not published]"
      assert [%{witnessed_at: nil}] = Checkpoint.recent(org_id)
    end
  end

  describe "auditing" do
    test "a run that matches the witness reports no discrepancies and exits 0", %{
      dir: dir,
      org_id: org_id
    } do
      with_witness(dir)
      published_page()
      Task.run(["--org", org_id])

      # No exit at all: `catch_exit` would swallow one, so the absence is the
      # assertion — `run/1` returning normally is the green path.
      Task.run(["--audit", "--org", org_id])

      assert output() =~ "0 checkpoint discrepancy/ies."
    end

    test "a deleted row the witness still holds is named as a truncation", %{
      dir: dir,
      org_id: org_id
    } do
      with_witness(dir)
      published_page()
      Task.run(["--org", org_id])
      [checkpoint] = Checkpoint.recent(org_id)

      # What truncating an anchor chain has to do first.
      excise!(checkpoint)

      assert {:shutdown, 1} = audit(["--org", org_id])
      out = output()

      assert out =~ "the WITNESS holds this checkpoint and the database does not"
      assert out =~ "1 checkpoint discrepancy/ies."
    end

    test "a row rewritten in place no longer matches what was published", %{
      dir: dir,
      org_id: org_id
    } do
      with_witness(dir)
      published_page()
      Task.run(["--org", org_id])
      [checkpoint] = Checkpoint.recent(org_id)

      KilnCMS.Repo.update_all(
        from(c in "chain_checkpoints", where: c.id == type(^checkpoint.id, :binary_id)),
        set: [root: String.duplicate("0", String.length(checkpoint.root))]
      )

      assert {:shutdown, 1} = audit(["--org", org_id])
      assert output() =~ "the published checkpoint does not match the database row"
    end

    test "a gap in the sequence is a discrepancy on its own", %{dir: dir, org_id: org_id} do
      with_witness(dir)

      for _ <- 1..3 do
        published_page()
        Task.run(["--org", org_id])
      end

      assert [_three, _two, _one] = Checkpoint.recent(org_id)

      # The MIDDLE one: a run truncated at the newest end leaves 1..n-1, which
      # is still contiguous — the moduledoc says so, and this check is for the
      # excision that leaves a hole.
      middle = Enum.find(Checkpoint.recent(org_id), &(&1.sequence == 2))

      excise!(middle)

      assert {:shutdown, 1} = audit(["--org", org_id])
      assert output() =~ "the sequence is not contiguous down to 1"
    end

    test "no witness configured is a failed audit, not a skipped one", %{org_id: org_id} do
      without_witness()
      published_page()
      Task.run(["--org", org_id])

      assert {:shutdown, 1} = audit(["--org", org_id])
      out = output()

      # A deployment with nothing outside the database attesting its
      # checkpoints has not been audited, whatever the structure looks like.
      assert out =~ "No witness is configured (KILN_GOVERNANCE_WITNESS)"
      assert out =~ "1 checkpoint discrepancy/ies."
    end

    test "the structural half still runs with no witness", %{org_id: org_id} do
      without_witness()

      for _ <- 1..3 do
        published_page()
        Task.run(["--org", org_id])
      end

      middle = Enum.find(Checkpoint.recent(org_id), &(&1.sequence == 2))
      excise!(middle)

      assert {:shutdown, 1} = audit(["--org", org_id])
      out = output()

      # Every reason, not just the missing witness: on an unsigned deployment
      # the structural checks are the only evidence there is, so they must not
      # be gated behind the sink. Both of them see this excision — the sequence
      # has a hole, and the successor now names no predecessor — and the count
      # includes the absent witness itself.
      assert out =~ "the sequence is not contiguous down to 1: [3, 1]"
      assert out =~ "checkpoint 3 names no predecessor, but the run does not start until 1"
      assert out =~ "No witness is configured"
      assert out =~ "3 checkpoint discrepancy/ies."
    end
  end

  describe "arguments" do
    test "--org limits the run to that organization", %{dir: dir, org_id: org_id} do
      with_witness(dir)
      other = KilnCMS.OrgFixtures.org("checkpoint-other")
      published_page()

      Task.run(["--org", org_id])
      out = output()

      assert out =~ org_id
      refute out =~ other.id
    end

    test "an unknown switch is refused rather than ignored" do
      assert_raise OptionParser.ParseError, fn -> Task.run(["--orgs", "all"]) end
    end
  end
end
