defmodule KilnCMS.Media do
  @moduledoc """
  The media pipeline behind `KilnCMS.CMS.MediaItem`: `KilnCMS.Media.Ingest`
  stores an upload, `KilnCMS.Media.VariantWorker` and `KilnCMS.Media.AVWorker`
  derive its variants, poster and dimensions, `KilnCMS.Media.AVStripWorker`
  strips an A/V upload's metadata and releases its quarantine,
  `KilnCMS.Media.QuarantineReaper` removes a quarantine that never cleared, and
  `KilnCMS.Media.Regeneration` re-enqueues variant work over a library.

  This module holds the one thing they share: the actor that pipeline runs as
  (#1659).
  """

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor the media pipeline runs as: the workers' re-read of the item they
  were enqueued for, their `:record_processing` and `:release_quarantine`
  writes, the regeneration scan, and the reaper's scan and `:purge`.

  A `KilnCMS.SystemActor`, admitted by action name on `CMS.MediaItem` (see
  `docs/policy-matrix.md`, "The system actor"), rather than `authorize?:
  false`, which would skip every policy on it. It may not run `:update`
  (which can gate an item and relocate its blob), `:update_metadata`, the soft
  `:destroy`, or `:purge` on an item that is not quarantined.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:media)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process. It exists so a test can take the grant away and prove that the
  # reads a worker decides on fail CLOSED rather than filtering to "gone",
  # which is how a refused read answers. Process-local, and nothing on a
  # request path calls it; code that could call it could equally pass any
  # actor it liked.
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
