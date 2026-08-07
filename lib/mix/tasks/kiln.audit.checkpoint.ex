defmodule Mix.Tasks.Kiln.Audit.Checkpoint do
  @shortdoc "Mint or audit governance chain checkpoints (#666)"

  @moduledoc """
  Governance checkpoints: the signed, org-wide commitment to every document's
  head anchor that makes truncating a chain's newest anchors detectable.

      mix kiln.audit.checkpoint            # mint one per org now, and publish it
      mix kiln.audit.checkpoint --audit    # compare the published copies to the database

  ## `--audit` is the half that matters

  Minting and publishing produce a record; they do not check anything. `--audit`
  re-fetches every checkpoint from the configured witness and compares it to the
  row, so these become visible:

    * a checkpoint **row deleted** — the sink has one the database does not;
    * a checkpoint **row rewritten** — the roots or signatures differ;
    * a checkpoint **never published** — the row has no receipt, so nothing
      outside the database attests it.

  ## The structural half runs without a sink

  Contiguity and the predecessor links (#732) are derived from
  `chain_checkpoints` alone, so they run on **every** deployment, including the
  default one that publishes nowhere. On a deployment with a witness they add
  little — `compare/2` re-derives the whole published document and already sees
  any in-place rewrite. On one without, they are the only structural evidence
  there is.

  Read them for what they are. An attacker who can rewrite a row can recompute
  every digest downstream of it, and the newest checkpoint has no successor to
  record its digest at all — so this is a check on a *careless* edit, and a
  multiplier against a careful one (cascading forces a rewrite of every published
  object after the doctored row, turning one sink mismatch into many). It is not
  a substitute for the witness.

  Run it from somewhere that is **not** the application host, using credentials
  that can read the sink and not write it. An audit run on the same machine, by
  the same role that writes the checkpoints, checks that a system agrees with
  itself. Exits non-zero if any comparison fails.
  """
  use Mix.Task

  alias KilnCMS.Governance.Checkpoint
  alias KilnCMS.Governance.CheckpointWorker
  alias KilnCMS.Governance.Witness

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [audit: :boolean, org: :string])

    orgs =
      case opts[:org] do
        nil -> KilnCMS.Accounts.list_org_ids()
        org_id -> [org_id]
      end

    Mix.shell().info("Witness: #{Witness.describe()}")

    if opts[:audit], do: audit(orgs), else: mint(orgs)
  end

  defp mint(orgs) do
    Enum.each(orgs, fn org_id ->
      case CheckpointWorker.run_for_org(org_id) do
        {:ok, checkpoint} ->
          Mix.shell().info(
            "#{org_id}: checkpoint #{checkpoint.sequence} over #{checkpoint.document_count} " <>
              "document(s), root #{String.slice(checkpoint.root, 0, 16)}… " <>
              published(checkpoint)
          )

        {:error, reason} ->
          Mix.shell().error("#{org_id}: no checkpoint was minted — #{inspect(reason)}")
      end
    end)
  end

  defp published(%{witnessed_at: nil, witness_error: nil}), do: "[not published]"
  defp published(%{witnessed_at: nil, witness_error: error}), do: "[NOT PUBLISHED: #{error}]"
  defp published(_checkpoint), do: "[published]"

  # Two halves, and only the second needs a sink.
  #
  # The structural checks — contiguity and the predecessor links (#732) — read
  # nothing but `chain_checkpoints`, so they run on EVERY deployment. That is the
  # only place they carry weight nothing else does: where a witness is
  # configured, `compare/2` re-derives the whole published document and so
  # already sees any in-place rewrite the links could. Gating them behind
  # `Witness.enabled?()` made them dead code on the default adapter
  # (`Witness.None`) — i.e. on precisely the unsigned deployments where they are
  # the only structural evidence available.
  #
  # The sink comparison still can't run without a sink, and saying so once beats
  # one error per checkpoint on every stock deployment — which trains operators
  # to ignore the exit code of the one tool that has to be trusted. It is still
  # a failure: a deployment with nothing outside the database attesting its
  # checkpoints has not been audited, whatever the structure looks like.
  defp audit(orgs) do
    structural = Enum.flat_map(orgs, &audit_structure/1)

    witnessed =
      if Witness.enabled?() do
        Enum.flat_map(orgs, &audit_org/1)
      else
        Mix.shell().error(
          "No witness is configured (KILN_GOVERNANCE_WITNESS), so checkpoints exist only in " <>
            "the database and there is nothing outside it to audit them against. The " <>
            "structural checks above still ran, but they cannot see a run truncated at the " <>
            "newest end, and an attacker who rewrites a row can recompute every digest " <>
            "downstream of it. See #666."
        )

        [:error]
      end

    Mix.shell().info("#{length(structural ++ witnessed)} checkpoint discrepancy/ies.")

    if structural != [] or witnessed != [], do: exit({:shutdown, 1})
  end

  # The half that needs no sink: everything derivable from the rows themselves.
  defp audit_structure(org_id) do
    rows = Checkpoint.recent(org_id)

    Enum.reject([contiguous(rows)] ++ links(rows), &(&1 == :ok))
  end

  # Both directions, and the second is the load-bearing one.
  #
  # Walking database rows and asking the sink about each can only find an object
  # that is missing or altered — it iterates the table the attacker just edited,
  # so a DELETED row is never looked up and never noticed. That is exactly what a
  # truncation produces, and it is what the moduledoc promises to catch. Listing
  # the sink and looking for keys the database no longer has is the half that
  # actually answers it.
  defp audit_org(org_id) do
    rows = Checkpoint.recent(org_id)
    row_sequences = MapSet.new(rows, & &1.sequence)

    Enum.reject(
      Enum.map(rows, &compare(&1, org_id)) ++ orphans(org_id, row_sequences),
      &(&1 == :ok)
    )
  end

  # Walk the `prev_checkpoint_id` / `prev_checkpoint_digest` links (#732).
  # `contiguous/1` above reads the sequence NUMBERS; this reads what each row
  # actually recorded about its predecessor, which is what makes a row rewritten
  # in place visible without a signature to check it against.
  #
  # The rule lives in `Checkpoint.link_failures/1` so it is unit-testable
  # against hand-built runs; this only formats.
  defp links(rows) do
    Enum.map(Checkpoint.link_failures(rows), &fail("checkpoints", &1))
  end

  # Keys the sink holds that the database no longer accounts for.
  defp orphans(org_id, row_sequences) do
    case Witness.list(org_id) do
      {:ok, keys} ->
        for key <- keys,
            sequence = Witness.sequence_from_key(key),
            is_nil(sequence) or not MapSet.member?(row_sequences, sequence) do
          fail(
            key,
            "the WITNESS holds this checkpoint and the database does not. A checkpoint row " <>
              "was deleted, which is what truncating an anchor chain has to do first"
          )
        end

      {:error, reason} ->
        [fail(org_id, "the witness could not be listed: #{inspect(reason)}")]
    end
  end

  # A gap in the run means a checkpoint was excised. Cheap here — one org's
  # checkpoints, once per audit — where `Chain.verify/4` could not afford it per
  # document.
  defp contiguous([]), do: :ok

  defp contiguous(rows) do
    sequences = rows |> Enum.map(& &1.sequence) |> Enum.sort(:desc)

    if sequences == Enum.to_list(length(sequences)..1//-1) do
      :ok
    else
      fail("checkpoints", "the sequence is not contiguous down to 1: #{inspect(sequences)}")
    end
  end

  # The comparison is over the CANONICAL document, not the raw bytes: the sink
  # holds what `Checkpoint.document/2` produced, and re-deriving it from the row
  # is what makes a rewritten row visible. Byte equality is the right test
  # precisely because the encoding is canonical — a difference is a difference in
  # content, never in field order.
  defp compare(checkpoint, org_id) do
    key = Witness.key(org_id, checkpoint.sequence)

    case Witness.fetch(key) do
      {:ok, published} ->
        if published == Checkpoint.document(checkpoint, org_id) do
          :ok
        else
          fail(key, "the published checkpoint does not match the database row")
        end

      {:error, :not_published} ->
        fail(key, "MISSING from the witness — the row exists but nothing outside attests it")

      {:error, reason} ->
        fail(key, "could not be read from the witness: #{inspect(reason)}")
    end
  end

  defp fail(key, message) do
    Mix.shell().error("#{key}: #{message}")
    :error
  end
end
