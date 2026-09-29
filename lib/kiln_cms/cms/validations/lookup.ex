defmodule KilnCMS.CMS.Validations.Lookup do
  @moduledoc """
  Who a CMS validation reads as when it looks something up (#1659).

  A validation that checks a reference ("is this release still open?", "does
  this record exist?", "how many items does this release hold?") used to read
  with `authorize?: false`. It now reads one of two ways, and both **fail
  closed**: a refused read rejects the write (as the `Ash.Error.Forbidden` it
  is, or as a "could not be checked" error), never an empty answer the
  validation acts on.

  ## As the caller — `as_caller/2`

  The default. The lookup runs with the actor and the authorization mode of the
  action being validated, so it can see exactly what the caller can see:

    * a request that is **authorized** (an editor in the console, an API
      client) reads under the policies, as that actor. Every reference these
      validations check is one the caller could already read — a release they
      are composing, a record they are adding to it, a menu item they are
      moving — so nothing legitimate is refused;
    * a caller that **bypassed** authorization for the action itself (a
      worker, a seed, the starter content) reads the same way it writes. The
      validation sees no more than the action it guards was already allowed
      to write, which is where it stood before.

  Every read passes `authorize_with: :error`, so a refusal under a filter
  policy is `Ash.Error.Forbidden`, not a quietly shorter list. That matters
  most for counts and walks: a release's item count read short would let it
  grow past its cap, and a menu subtree read short would accept a move that
  nests too deep.

  ## As the system — `system/0`

  Only where the check must see rows the caller cannot. The publish gates
  (`KilnCMS.CMS.Validations.RequiredConsent`,
  `KilnCMS.CMS.Validations.MediaAltText`) also run for `:publish_scheduled`,
  whose caller is the AshOban scheduler: it has no actor, and it is admitted
  to the publish by `AshOban.Checks.AshObanInteraction`, which admits it to
  nothing else. Those two reads run as a `KilnCMS.SystemActor`, admitted by
  name on `CMS.Consent` (`for_content`) and `CMS.MediaItem` (`read`); see
  `docs/policy-matrix.md`, "The system actor".
  """

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  Read options that run a lookup as the caller of the action being validated.

  `context` is the validation's (or a change's) context; only its `:actor` and
  `:authorize?` are used. A context that did not authorize — `authorize?` is
  `false` or absent — keeps the lookup unauthorized too; see the moduledoc.
  """
  @spec as_caller(map(), term()) :: keyword()
  def as_caller(context, tenant) do
    [
      actor: Map.get(context, :actor),
      authorize?: Map.get(context, :authorize?) == true,
      authorize_with: :error,
      tenant: tenant
    ]
  end

  @doc """
  The actor the publish gates read as: a `KilnCMS.SystemActor`. See the
  moduledoc for why these two, and only these two, do not read as the caller.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil | struct()
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:publish_gate)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process, so a test can take the grant away and prove that a publish gate
  # fails CLOSED (the publish is refused) rather than reading a refusal as "no
  # consent needed" or "not decorative". Process-local, and nothing on a
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
