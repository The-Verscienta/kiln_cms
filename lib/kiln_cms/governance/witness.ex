defmodule KilnCMS.Governance.Witness do
  @moduledoc """
  Publication of governance checkpoints **outside the database** (#666).

  Everything `KilnCMS.Governance.Chain` knows about a document lives in tables
  the same credentials can write. That closes rewriting and closes excision, and
  it cannot close *truncation*: nothing inside a document's own anchor set
  distinguishes "anchored five times, two deleted" from "anchored three times".
  The missing fact is how far the chain had got, recorded somewhere the attacker
  does not also control.

  A checkpoint (`KilnCMS.Governance.Checkpoint`) is that record: a signed
  commitment to every anchored document's head, minted on a schedule and handed
  to an adapter here for publication. The database keeps a copy so per-document
  verification is a local lookup; the published copy is what makes the copy
  worth anything, because it is the only one an attacker with full database
  control cannot edit.

  ## Adapters

    * `KilnCMS.Governance.Witness.None` — the default. Checkpoints are still
      minted and still detect an ordinary `DELETE` on `history_anchors`, since
      the checkpoint tables are a second place the attacker has to remember.
      They do **not** survive an attacker who deletes the checkpoint rows too.
      This is a real improvement over nothing and it is not the property the
      feature claims; deployments that need the claim configure a real sink.
    * `KilnCMS.Governance.Witness.File` — one file per checkpoint under a
      directory, created exclusively so an existing checkpoint is never
      overwritten. Point it at a mount the application user cannot unlink from
      (an append-only bind mount, a WORM volume, a syncing agent's spool).
    * `KilnCMS.Governance.Witness.S3` — one object per checkpoint, written with
      `If-None-Match: *` so a re-publish cannot silently replace one. Pair it
      with S3 Object Lock in compliance mode, or a bucket policy that denies
      `s3:DeleteObject` to the application's credentials; without one of those
      the object is as deletable as the row.

  Selection is `config :kiln_cms, KilnCMS.Governance.Witness, adapter: …`
  (`KILN_GOVERNANCE_WITNESS` in `config/runtime.exs`).

  ## What publication does and does not settle

  Publishing proves nothing on its own — a checkpoint nobody reads back is a
  file. The property arrives when someone **compares**: `mix kiln.audit.checkpoint
  --audit` re-fetches each published checkpoint and diffs it against the row,
  so a deleted or rewritten checkpoint table is visible. Run it from somewhere
  that is not the application host, on credentials that can read the sink and
  not write it. That separation is the whole mechanism; a sink the application
  can rewrite reproduces the problem one hop out.
  """

  @typedoc "Adapter-specific proof of publication, stored on the checkpoint row."
  @type receipt :: %{optional(String.t()) => term()}

  @doc """
  Publish `body` at `key`. Must not overwrite an existing object at that key —
  a sink that silently replaces one lets an attacker who can write it rewrite
  history, which is the thing being defended against. Report
  `{:error, :already_published}` instead.
  """
  @callback publish(key :: String.t(), body :: binary()) :: {:ok, receipt()} | {:error, term()}

  @doc "Read back what was published at `key`, for the audit comparison."
  @callback fetch(key :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Every key this sink holds for `org_id`.

  The audit's *other* direction, and the load-bearing one. Comparing database
  rows against the sink can only ever find a row whose object is missing or
  altered — it iterates the table the attacker just edited, so a **deleted** row
  is never looked up and never noticed. Enumerating the sink is what makes
  "the witness has a checkpoint the database does not" answerable at all, and
  that is the case a truncation attack actually produces.
  """
  @callback list(org_id :: String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "One line naming where this adapter writes, for operator-facing output."
  @callback describe() :: String.t()

  @doc "The configured adapter module."
  @spec adapter() :: module()
  def adapter do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, KilnCMS.Governance.Witness.None)
  end

  @doc "Whether a real (non-`None`) sink is configured."
  @spec enabled?() :: boolean()
  def enabled?, do: adapter() != KilnCMS.Governance.Witness.None

  @doc """
  The key one org's checkpoint is published under.

  Zero-padded so a lexicographic listing of the sink is also chronological —
  the first thing an auditor does with a bucket is list it, and `10` sorting
  before `9` makes a gap easy to miss.
  """
  @spec key(Ash.UUID.t(), pos_integer()) :: String.t()
  def key(org_id, sequence) do
    "#{org_id}/#{sequence |> Integer.to_string() |> String.pad_leading(12, "0")}.json"
  end

  @doc "Publish through the configured adapter."
  @spec publish(String.t(), binary()) :: {:ok, receipt()} | {:error, term()}
  def publish(key, body), do: adapter().publish(key, body)

  @doc "Fetch through the configured adapter."
  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(key), do: adapter().fetch(key)

  @doc "List one org's published keys through the configured adapter."
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(org_id), do: adapter().list(org_id)

  @doc """
  The sequence number a published key names, or nil if it is not one of ours.

  The inverse of `key/2`. The audit needs it to line the sink's contents up
  against the database's, and it is deliberately strict: a key this cannot parse
  is reported rather than skipped, since a sink holding objects Kiln did not
  write is itself worth knowing about.
  """
  @spec sequence_from_key(String.t()) :: pos_integer() | nil
  def sequence_from_key(key) do
    with basename when is_binary(basename) <- Path.basename(key, ".json"),
         {sequence, ""} <- Integer.parse(basename) do
      sequence
    else
      _ -> nil
    end
  end

  @doc "Describe the configured adapter."
  @spec describe() :: String.t()
  def describe, do: adapter().describe()

  @doc ~S"""
  The short name recorded on a checkpoint row: `"none"`, `"file"`, `"s3"`, …
  """
  @spec name() :: String.t()
  def name do
    adapter()
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  @doc "Adapter config, read at call time so a runtime change takes effect."
  @spec config(module()) :: keyword()
  def config(module), do: Application.get_env(:kiln_cms, module, [])
end
