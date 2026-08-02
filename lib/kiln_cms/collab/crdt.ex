defmodule KilnCMS.Collab.Crdt do
  @moduledoc """
  Real-time **CRDT text collaboration** — the prototype from
  `docs/collaborative-editing-spike.md` (scoping D1: rich text within a
  block). Complements `KilnCMS.Collab`, the coarse block-op/event layer: block
  add/remove/reorder stays op-based; concurrent typing *inside* a rich-text
  block converges through Yjs.

  The BEAM is a first-class Yjs node: one `KilnCMS.Collab.Crdt.DocServer` per
  open document holds the authoritative `Yex.Doc`, applies binary Yjs updates
  relayed over `KilnCMSWeb.CollabChannel`, and hands the full state to each
  joining client. Browsers run TipTap's Collaboration extension bound to a
  per-block `XmlFragment` of the same doc (see `assets/js/collab.js`).

  Behind the `:collab_prototype` config flag (on in dev, off in prod) — the
  channel refuses joins when disabled, so shipping the code is inert.

  Docs are **durable across restarts**: each DocServer lazy-restores its Yjs
  state from `collab_doc_states`, checkpoints while dirty, and flushes on
  shutdown (see `DocServer`). Content durability additionally flows through
  the editor's HTML-mirror autosave, so even a hard kill loses no prose.
  """

  require Logger

  alias KilnCMS.Collab.Crdt.DocServer

  @doc "Whether the collaborative-editing CRDT prototype is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:kiln_cms, :collab_prototype, false)

  # How many documents may have a live authoritative doc server at once. Each
  # one holds a Yex NIF document in memory and lingers ten minutes past its last
  # client, so without a cap this is unbounded resident memory (#676).
  #
  # Counted in *documents being edited concurrently across the whole
  # deployment*, not editors — several editors on one document share one server.
  # 500 is generous for that: a newsroom with 500 documents open at the same
  # instant is a large newsroom, and the cost of being wrong is bounded and
  # visible (`ensure_server/2` logs and the client falls back to solo editing
  # with autosave), where the cost of no cap is a node running out of memory.
  @default_max_documents 500

  @doc """
  The concurrent open-document ceiling — `config :kiln_cms, :collab_max_documents`,
  default `#{@default_max_documents}`.

  Read at boot to size the `DynamicSupervisor`, so changing it needs a restart.
  """
  @spec max_documents() :: pos_integer()
  def max_documents do
    case Application.get_env(:kiln_cms, :collab_max_documents, @default_max_documents) do
      n when is_integer(n) and n > 0 -> n
      _invalid -> @default_max_documents
    end
  end

  @doc """
  Find or start the authoritative doc server for a channel topic.

  `org_id` is the tenant the joining channel authorized the document under
  (#655), carried so the server-side checkpoint writes back to the document's
  own site rather than the default org. Only the caller that *starts* the
  server sets it; a document id is unique across organizations, and every
  joiner has already had its read authorized under the org that holds it, so
  later joiners cannot disagree about which one that is.

  `{:error, :unavailable}` when the deployment already has `max_documents/0`
  documents open (#676) — a document already open is always joinable, since
  that path never starts anything. The caller refuses the join and the client
  degrades to solo editing with autosave, which is the same fallback it uses
  when the prototype is switched off entirely.
  """
  @spec ensure_server(String.t(), Ash.UUID.t()) :: {:ok, pid()} | {:error, :unavailable}
  def ensure_server(doc_key, org_id) do
    child = {DocServer, {doc_key, org_id}}

    case DynamicSupervisor.start_child(KilnCMS.Collab.Crdt.DocSupervisor, child) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, :max_children} ->
        # Loud: this is a capacity limit being reached, not a client error, and
        # the only other symptom is editors quietly losing collaboration.
        Logger.error(
          "Collab document limit reached (#{max_documents()}); refusing #{doc_key}. " <>
            "Raise :collab_max_documents if this is legitimate load."
        )

        {:error, :unavailable}
    end
  end

  defdelegate attach(server), to: DocServer
  defdelegate apply_update(server, update), to: DocServer
  defdelegate state_update(server), to: DocServer
end
