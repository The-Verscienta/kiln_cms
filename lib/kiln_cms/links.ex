defmodule KilnCMS.Links do
  @moduledoc """
  The link checker (#474): `KilnCMS.Links.Internal` resolves a document's
  same-origin links in the editor, and `KilnCMS.Links.Sweep` /
  `KilnCMS.Links.CheckWorker` find and check its outbound ones on a schedule.

  This module holds the one thing they share: the actor the link checker's own
  bookkeeping runs as (#1659).
  """

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

  Typed `term()`: under `with_actor/2` it answers whatever the test put there.
  """
  @spec system() :: term()
  def system, do: KilnCMS.SystemActor.resolve(:links)

  @doc false
  # Test seam (#1659): `KilnCMS.SystemActor.with_override/3` for `:links`.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun), do: KilnCMS.SystemActor.with_override(:links, actor, fun)
end
