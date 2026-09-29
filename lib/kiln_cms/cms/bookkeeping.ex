defmodule KilnCMS.CMS.Bookkeeping do
  @moduledoc """
  The actor the CMS's own write-side bookkeeping runs as (#1659).

  Some changes attached to content, comment and form actions write or read
  something the *caller* has no grant for, because the write is not theirs —
  it is the action's consequence:

    * a publish completes the record's open tasks
      (`KilnCMS.CMS.Changes.AutoCompleteTasks`) — a scheduled publish has no
      person behind it at all;
    * a publish or unpublish points `published_version_id` at the version
      PaperTrail just wrote (`RecordPublishedVersion`, `ClearPublishedVersion`);
    * an editor's rename of a published slug leaves a 301 behind
      (`RecordSlugRedirect`), and redirects are admin-only to write;
    * every content write reads the custom-field registry it validates
      against (`ApplyCustomFields`), whoever the writer is;
    * an anonymous form submission is scored against the site's spam keywords
      (`ScoreFormSubmission`), which only an admin may read.

  Each used to run `authorize?: false`. They now run as this
  `KilnCMS.SystemActor`, admitted by action name on each resource — see
  `docs/policy-matrix.md`, "The system actor". Anything a change can do as the
  caller (a comment thread read, a release item cancel, a reference lookup)
  stays the caller's.
  """

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor CMS bookkeeping runs as: a `KilnCMS.SystemActor` labelled
  `:cms_bookkeeping`.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:cms_bookkeeping)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process. It exists so a test can take the grant away and prove that the
  # reads a change decides on fail CLOSED rather than filtering to "none",
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
