defmodule KilnCMS.CMS.Housekeeping do
  @moduledoc """
  The actor the CMS's own helper modules run as when there is no caller to run
  as (#1659).

  A handful of helpers read something the request's own actor has no grant
  for, or run with no actor at all:

    * the field and type registry (`FieldDefinition`, `TypeDefinition`) that
      slug derivation (`KilnCMS.CMS.Slugs`), the custom-field filter
      (`KilnCMS.CMS.Preparations.CustomFieldQuery`), the name-field index
      (`KilnCMS.CMS.NameFields`) and the dynamic-type registry
      (`KilnCMS.CMS.ContentTypes`) consult on every write and every public
      read, anonymous ones included;
    * the site's editorial settings row (`KilnCMS.CMS.EditorialSettings`,
      `KilnCMS.CMS.TaskSettings`), asked from inside a publish whose caller may
      be the scheduler;
    * a content release's own bookkeeping (`KilnCMS.CMS.Releases`,
      `KilnCMS.CMS.Workers.ReleaseWorker`): the release and its items, which
      the go-live worker reads and marks after an admin claimed the release.

  Each used to run `authorize?: false`. They now run as a
  `KilnCMS.SystemActor`, admitted by action name on each resource — see
  `docs/policy-matrix.md`, "The system actor". Every read that decides
  something passes `authorize_with: :error`, so a refusal raises rather than
  filtering to "nothing".

  `system/1` takes the caller's subsystem label rather than inventing one for
  this module, and the label is the grant (#1747): each clause of
  `KilnCMS.Checks.SystemActor` names the subsystems it admits. The labels here
  hold unrelated grants — `:releases` writes a release's outcome,
  `:cms_registry` and `:promotion` read the field and type registry,
  `:cms_settings` reads one settings row — so they stay distinct rather than
  folding into one CMS actor, and stay distinct from
  `KilnCMS.CMS.Bookkeeping`'s `:cms_bookkeeping`, whose writes (completing
  tasks, pointing a record at its published version, redirects) none of them
  may make.
  """

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor a CMS helper runs as: a `KilnCMS.SystemActor` labelled
  `subsystem` (`:cms_registry`, `:cms_settings`, `:releases`).
  """
  @spec system(atom()) :: KilnCMS.SystemActor.t() | nil
  def system(subsystem) when is_atom(subsystem) do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(subsystem)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/1` answering `actor` in this
  # process. It exists so a test can take the grant away and prove that the
  # reads a helper decides on fail CLOSED rather than filtering to "none",
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
