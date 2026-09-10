defmodule KilnCMS.Accounts.Bootstrap do
  @moduledoc """
  First-run bootstrap: creates the instance's first admin account (#1317).

  Until now the only production path to a first admin was `bin/kiln_cms remote`
  and pasting Elixir with `authorize?: false` (README). The `/setup` wizard
  replaces that, and this module is its write side — the wizard itself holds no
  privilege.

  ## Why this is safe to expose unauthenticated

  An exposed installer on a deployed-but-unconfigured instance is a classic
  takeover surface (the WordPress install page), so the gate is layered:

    * **Policy** — `User.:bootstrap_admin` authorizes only while
      `Checks.NoAdminExists` holds, so every path to the action — not just this
      module — dies with `Forbidden` the moment an admin exists. No
      `authorize?: false` anywhere in the flow.
    * **Serialization** — the check is a plain read, so two concurrent callers
      could both see "no admin" (check-then-act, the shape #742 documents).
      `create_first_admin/1` takes a transaction-scoped Postgres advisory lock
      and re-reads under it, so exactly one of a race's callers creates the
      account and the rest get `:already_bootstrapped`.
    * **Scope** — the action creates one confirmed admin from typed
      credentials. It mints no session token; the caller signs in through the
      normal password flow, second factors and all.

  Seeds remain the dev/CI path (`priv/repo/seeds.exs` creates a pre-confirmed
  admin, which makes `bootstrapped?/0` true and the wizard disappear).
  """

  require Ash.Query

  alias KilnCMS.Accounts.User
  alias KilnCMS.Repo

  # Identifies this lock across the cluster. Advisory locks are keyed by
  # bigint; this one is arbitrary but must stay stable and collide with no
  # other advisory lock the app takes.
  @lock_key 131_700_000_001

  @doc """
  Whether the instance already has an admin account — the wizard's gate,
  inverted by `Checks.NoAdminExists` for the policy.

  A system read: this runs for anonymous visitors (deciding whether `/setup`
  renders) and inside the policy check itself, where there is no actor to
  authorize as. It reads only existence, never rows.
  """
  @spec bootstrapped?() :: boolean()
  def bootstrapped? do
    User
    |> Ash.Query.filter(role == :admin)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  @doc """
  Create the first admin from the wizard's typed credentials — `{:ok, user}`,
  `{:error, :already_bootstrapped}`, or `{:error, changeset_error}` for
  invalid input.

  Runs the `:bootstrap_admin` action **with authorization on** (the policy is
  the outer gate), inside an advisory-locked transaction that re-checks the
  condition (the race gate). The lock is transaction-scoped, so it cannot leak
  on a crashed caller.
  """
  @spec create_first_admin(map()) ::
          {:ok, User.t()} | {:error, :already_bootstrapped | term()}
  def create_first_admin(attrs) when is_map(attrs) do
    case Repo.transaction(fn -> locked_create(attrs) end) do
      {:ok, user} -> {:ok, reload!(user)}
      {:error, :already_bootstrapped} -> {:error, :already_bootstrapped}
      {:error, error} -> {:error, error}
    end
  end

  defp locked_create(attrs) do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock_key])

    if bootstrapped?() do
      Repo.rollback(:already_bootstrapped)
    else
      create_admin!(attrs)
    end
  end

  defp create_admin!(attrs) do
    case User |> Ash.Changeset.for_create(:bootstrap_admin, attrs) |> Ash.create() do
      {:ok, user} -> user
      {:error, error} -> Repo.rollback(error)
    end
  end

  # The create ran with no actor, so the User field policies scrubbed `:role`
  # (and `:email`) on the returned struct — and a struct whose role is a
  # forbidden-field marker fails `Scoping.effective_tier/2`'s admin clause, so
  # the wizard's follow-up branding save would be refused for the very admin it
  # just created. Re-read as a system call: this is the record the caller is
  # about to act AS, not data served to an untrusted reader.
  defp reload!(user) do
    Ash.get!(User, user.id, authorize?: false)
  end
end
