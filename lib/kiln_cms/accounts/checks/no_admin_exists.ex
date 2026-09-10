defmodule KilnCMS.Accounts.Checks.NoAdminExists do
  @moduledoc """
  True while the instance has no `:admin` user — the gate on
  `User.:bootstrap_admin` (#1317).

  This is the "install page" condition: an anonymous caller may create the
  first admin precisely because there is nobody yet who could authorize it, and
  must never create the second one. The check alone is not the whole guarantee
  — two concurrent callers can both read "no admin" under READ COMMITTED — so
  `KilnCMS.Accounts.Bootstrap` serializes the create behind an advisory lock
  and re-checks inside it. The policy check is what keeps every *other* path to
  the action (a future surface, a console call without the module) fail-closed
  rather than relying on nobody wiring one up.

  A DB read inside a policy check is deliberate here: the action runs at most
  once in an install's lifetime, and after that this check short-circuits every
  attempt to `Forbidden` before any change runs.
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "no admin account exists yet (first-run bootstrap)"

  @impl Ash.Policy.SimpleCheck
  def match?(_actor, _context, _opts), do: not KilnCMS.Accounts.Bootstrap.bootstrapped?()
end
