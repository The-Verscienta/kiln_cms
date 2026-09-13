defmodule KilnCMS.Checks.SystemActor do
  @moduledoc """
  Matches `%KilnCMS.SystemActor{}` — a trusted internal caller (#1402).

  Admits worker, scheduler, delivery-bookkeeping and mix-task code to one
  specific action on one specific resource, in place of the `authorize?: false`
  that admitted it to *everything* on that resource. See `KilnCMS.SystemActor`
  for what the actor is and is not, and `docs/policy-matrix.md` ("The system
  actor") for the resources that admit it.

  ## Use `authorize_if`, not `bypass`

      policy action_type([:create, :update, :destroy]) do
        authorize_if KilnCMS.Checks.SystemActor
        forbid_if always()
      end

  A `bypass` short-circuits **every policy below it** on the resource, so
  `bypass KilnCMS.Checks.SystemActor` is the same total grant
  `authorize?: false` gave, only spelled differently — and it would silently
  swallow a policy a later PR adds beneath it. An `authorize_if` grants exactly
  the policy it is written in; a new policy elsewhere in the stack still
  applies to system code until someone deliberately admits it there too. That
  visibility is the entire point of the exercise, so this check must never
  appear in a `bypass` — `KilnCMS.PolicyCoverageTest` fails the build if it
  does.

  ### When the resource already has a broad policy written for people

  Ash **ANDs** policies, so on a resource whose `action_type(:update)` policy
  exists for people (content — `KilnCMS.CMS.Checks.EditableContentType`),
  adding a *second* policy that admits system code changes nothing: the broad
  one still applies and still refuses. Widening that policy outright would
  grant system code every update on the resource, which is the opposite of
  scoped.

  The answer is still not a bypass. Narrow the grant **inside** the policy
  that would otherwise refuse, using `action/1` as a check:

      policy action_type([:create, :update]) do
        authorize_if KilnCMS.CMS.Checks.EditableContentType

        # System-only actions, and only those.
        forbid_unless action([:reindex_search_text, :set_embedding])
        authorize_if KilnCMS.Checks.SystemActor
      end

  For a person the first clause has already decided, so the two below it are
  unreachable; for a system actor every action but the two named forbids at
  the second. Nothing is short-circuited, so every other policy on the
  resource — including one a later PR adds — still applies to system code.

  The one place a top-of-stack clause is already correct is
  `AshOban.Checks.AshObanInteraction` on `publish_scheduled`, where the caller
  genuinely *is* the AshOban scheduler and Ash itself vouches for that: the
  check reads the trigger metadata Ash put on the changeset, not an actor the
  caller chose. Prefer it wherever the caller is the scheduler; this check is
  for the much larger set of callers that are not.

  ## Matching

  Matches on the **actor** struct only, and on nothing about the subject. A
  check that pattern-matched the *resource* struct would be a compile-time
  cycle with the `policies` block naming it (see
  `KilnCMS.CMS.Checks.EditorMayPublish`); `KilnCMS.SystemActor` is a plain
  struct that depends on nothing, so naming it here is safe.

  Scope is not expressed here. Which subsystem may do what is decided by which
  resources and actions carry this clause — not by inspecting
  `SystemActor.subsystem`, which is provenance for logs.
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "a KilnCMS system actor (internal worker/job/task)"

  @impl Ash.Policy.SimpleCheck
  def match?(%KilnCMS.SystemActor{}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
