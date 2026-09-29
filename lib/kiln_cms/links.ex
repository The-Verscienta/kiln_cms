defmodule KilnCMS.Links do
  @moduledoc """
  The link checker (#474): `KilnCMS.Links.Internal` resolves a document's
  same-origin links in the editor, and `KilnCMS.Links.Sweep` /
  `KilnCMS.Links.CheckWorker` find and check its outbound ones on a schedule.

  This module holds the one thing they share: the actor the link checker's own
  bookkeeping runs as (#1659).
  """

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor the link checker's bookkeeping runs as: the sweep's observe, prune
  and enqueue over `CMS.ExternalLink`, the check worker's verdict writes, and
  the reads and `record_sweep` stamp on `CMS.SiteLinkCheck`.

  A `KilnCMS.SystemActor`, admitted by name on those two resources (see
  `docs/policy-matrix.md`, "The system actor"), rather than `authorize?: false`,
  which would skip every policy on them.

  The content reads stay `authorize?: false`, each with its reason at the call
  site: a system-actor grant on content would be a standing read over the
  whole corpus, drafts included, which is wider than the one sweep it serves
  (the #1402 argument).
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:links)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process. It exists so a test can take the grant away and prove that the
  # reads backing the retry-before-flagging counter and the sweep fail CLOSED
  # rather than filtering to "nothing", which is how a refused read answers.
  # Process-local, and nothing on a request path calls it; code that could
  # call it could equally pass any actor it liked.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun) do
    previous = Process.get(@actor_override, :unset)
    Process.put(@actor_override, actor)

    try do
      fun.()
    after
      if previous == :unset,
        do: Process.delete(@actor_override),
        else: Process.put(@actor_override, previous)
    end
  end
end
