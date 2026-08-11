defmodule KilnCMS.Governance.Witness.None do
  @moduledoc """
  The default witness: nothing is published (#666).

  Checkpoints are still minted, signed and stored, and they still catch the
  attack the issue describes in its ordinary form — an attacker who deletes a
  document's newest anchors and leaves `chain_checkpoint_entries` alone now
  produces `{:tampered, …}` rather than `:verified`.

  What it does not survive is an attacker who remembers the second table. Delete
  a document's `chain_checkpoint_entries` rows along with its anchors and the
  witness is simply gone — nothing inside the database can distinguish that from
  a document no checkpoint ever covered, which is the same argument that made
  the checkpoints necessary one level down. Only a real sink closes it, because
  only a real sink can be *enumerated*: `mix kiln.audit.checkpoint --audit` lists
  what was published and looks for what the database no longer has.

  Saying so is the point of having a named adapter rather than a nil. The
  configured sink is recorded on every checkpoint row and reported by
  `mix kiln.audit.checkpoint`, so "unwitnessed" is a state an operator can read
  rather than infer.
  """
  @behaviour KilnCMS.Governance.Witness

  @impl true
  def publish(_key, _body), do: {:error, :no_witness_configured}

  @impl true
  def fetch(_key), do: {:error, :no_witness_configured}

  @impl true
  def list(_org_id), do: {:error, :no_witness_configured}

  @impl true
  def describe, do: "none (checkpoints are stored in the database only)"
end
