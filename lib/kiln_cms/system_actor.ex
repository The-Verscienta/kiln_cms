defmodule KilnCMS.SystemActor do
  @moduledoc """
  The actor for a trusted internal caller — a worker, a scheduled job, a
  delivery-path bookkeeping write, a mix task (#1402).

  Before this existed, code with no request actor reached its resource through
  `authorize?: false`, which skips *every* policy on that resource — including
  the ones a later PR adds, and including any policy declared below a `bypass`
  (`docs/policy-matrix.md`, "The system actor"). #1309 counted 563 such sites;
  each one is a piece of the authorization surface that no policy block, and no
  line of `docs/policy-matrix.md`, describes.

  A system actor moves those callers *under* the policies instead of around
  them:

      # before — invisible to the policy block and to the matrix
      Ash.bulk_destroy!(query, :destroy, %{}, authorize?: false, tenant: org_id)

      # after — the resource's policies decide, and say so
      Ash.bulk_destroy!(query, :destroy, %{}, actor: SystemActor.new(:firing), tenant: org_id)

  ## What it is not

  **It is not a privilege boundary against our own code.** Any module that can
  call `SystemActor.new/1` could equally have written `authorize?: false`. What
  it buys is different and narrower:

    * **The grant is declared.** `KilnCMS.Checks.SystemActor` appears in the
      resource's `policies do` block, so "what system code may do here" is
      readable where every other grant is readable, and `docs/policy-matrix.md`
      can list it (a test enforces that it does — see
      `KilnCMS.PolicyCoverageTest`).
    * **A future policy still applies.** A bypass is permanent and total; an
      `authorize_if` clause covers exactly the policy it sits in. A policy added
      to the resource tomorrow constrains the system actor too, unless someone
      deliberately admits it there as well.
    * **Everything else on the resource keeps running.** Validations, changes
      and the tenant filter run for a system actor exactly as for a person.

  ## Shape

  Deliberately **not** a `KilnCMS.Accounts.User` and deliberately without an
  `:id` or a `:role`. Every actor-attribute check in the codebase resolves it
  to "nothing": `KilnCMS.Accounts.Scoping.effective_tier/2` returns `:none` (no
  `:role` key, no `:id` to look a membership up by) and
  `KilnCMS.Accounts.Scoping.audiences/2` returns `[]`. So a system actor cannot
  drift into a grant through a role or audience check that was written for
  people — the *only* way it is ever authorized is an explicit
  `KilnCMS.Checks.SystemActor` clause. `test/kiln_cms/system_actor_test.exs`
  pins that.

  `subsystem` is provenance, not permission: a label naming the caller, so an
  actor in a log line, a telemetry span or an `Ash.Error.Forbidden` says which
  worker was running. The check matches **any** system actor rather than a
  named one — scope belongs to the resource and action that admit it, and
  encoding the caller's identity a second time in the policy would let the two
  drift apart.

  ## Tenancy

  The actor answers **who**, never **which org**. A system call still passes
  `tenant:` explicitly, exactly as it did under `authorize?: false`;
  `multitenancy strategy :attribute` is untouched and a system actor gets no
  cross-tenant reach. See `docs/policy-matrix.md`, "The system actor".
  """

  @enforce_keys [:subsystem]
  defstruct [:subsystem]

  @type t :: %__MODULE__{subsystem: atom()}

  @doc """
  A system actor labelled with the subsystem running it.

  The label is free-form on purpose: an allowlist here would be a second
  roster to keep in sync with the one that matters, which is the set of
  resources whose policies admit `KilnCMS.Checks.SystemActor` (enumerated in
  `docs/policy-matrix.md` and enforced by `KilnCMS.PolicyCoverageTest`).

      iex> KilnCMS.SystemActor.new(:firing)
      %KilnCMS.SystemActor{subsystem: :firing}
  """
  @spec new(atom()) :: t()
  def new(subsystem) when is_atom(subsystem) and not is_nil(subsystem),
    do: %__MODULE__{subsystem: subsystem}

  @doc """
  The actor `subsystem`'s code runs as: `new(subsystem)`, unless a test has
  overridden it in this process (`with_override/3`).

  A subsystem that wants its missing-grant paths testable exposes this rather
  than `new/1` (`KilnCMS.Links.system/0`). The return is `term()`, not `t()`:
  an override can be any actor, including `nil` or a person.
  """
  @spec resolve(atom()) :: term()
  def resolve(subsystem) do
    case Process.get(override_key(subsystem), :unset) do
      :unset -> new(subsystem)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `resolve(subsystem)` answering `actor` in
  # this process, so a test can take a grant away and prove the reads behind a
  # decision fail CLOSED rather than filtering to "nothing". Process-local, and
  # nothing on a request path calls it; code that could call it could equally
  # pass any actor it liked. One copy here, rather than one per subsystem.
  @spec with_override(atom(), term(), (-> result)) :: result when result: term()
  def with_override(subsystem, actor, fun) do
    previous = Process.get(override_key(subsystem), :unset)
    put_override(subsystem, actor)

    try do
      fun.()
    after
      if previous == :unset,
        do: delete_override(subsystem),
        else: put_override(subsystem, previous)
    end
  end

  @doc false
  # The unscoped halves of `with_override/3`, for a test that must withdraw a
  # grant partway through a call (from inside an HTTP stub, say).
  @spec put_override(atom(), term()) :: :ok
  def put_override(subsystem, actor) do
    Process.put(override_key(subsystem), actor)
    :ok
  end

  @doc false
  @spec delete_override(atom()) :: :ok
  def delete_override(subsystem) do
    Process.delete(override_key(subsystem))
    :ok
  end

  defp override_key(subsystem), do: {__MODULE__, :override, subsystem}
end
