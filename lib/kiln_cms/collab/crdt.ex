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

  @doc """
  Whether the collaborative-editing CRDT prototype is enabled.

  Read fresh on every editor mount, from **VM-global** application env. A test
  that flips `:collab_prototype` therefore flips it for every session in the
  node, not just its own — so any such test must be `async: false`, or it
  disables collaboration underneath whatever else is mounting an editor at that
  moment (`KilnCMSWeb.CollabSavedRefreshTest`, `KilnCMSWeb.CollabChannelTest`).
  Restore the previous value rather than deleting the key: `config/test.exs`
  sets it at boot, and `Application.delete_env/2` would leave every later module
  on the `false` default here.
  """
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

  @doc """
  `record`'s blocks with the converged prose of its **already-open** room merged
  in, or `:none` when no room is open (#1061).

  Looks the server up rather than starting one — `ensure_server/2` would mint an
  empty doc for a record nobody is editing, and materializing an empty doc
  against a record replaces nothing but costs a process and a row. A publish
  with no room open must be exactly as cheap as it was before this existed.

  Failure is `:none`, not a raise. This runs inside a publish, and a collab
  prototype that is misbehaving must not be able to stop content going live —
  the pre-existing behaviour (lose the uncaptured prose) is bad, but refusing
  the publish outright is worse.
  """
  @spec converged_blocks(String.t(), struct()) :: {:ok, [map()]} | :none
  def converged_blocks(doc_key, record) do
    case Registry.lookup(KilnCMS.Collab.Crdt.Registry, doc_key) do
      [{pid, _value} | _] -> {:ok, DocServer.converged_blocks(pid, record)}
      [] -> :none
    end
  rescue
    # `Registry.lookup/2` RAISES on an unknown registry rather than exiting, so
    # the `catch` below cannot see it. Reachable in a release with the prototype
    # flag on and the collab subtree not started — where, without this, every
    # publish would log the deliberately-loud checkpoint warning and drown the
    # signal it exists for.
    ArgumentError -> :none
  catch
    # An `exit` from a server that stopped between the lookup and the call.
    :exit, _reason -> :none
  end

  @doc """
  The doc key for one content record — the channel topic without its prefix.
  """
  @spec doc_key(atom() | String.t(), Ash.UUID.t()) :: String.t()
  def doc_key(kind, id), do: "collab:#{kind}:#{id}"

  defdelegate attach(server), to: DocServer
  defdelegate apply_update(server, update), to: DocServer
  defdelegate state_update(server), to: DocServer
end
