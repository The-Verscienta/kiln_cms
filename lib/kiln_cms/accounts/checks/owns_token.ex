defmodule KilnCMS.Accounts.Checks.OwnsToken do
  @moduledoc """
  Matches the `KilnCMS.Accounts.Token` rows whose `subject` is the actor's own
  (#1823) — what "your sessions" on the settings page lists and signs out.

  A filter check, so it narrows rather than refuses: a read returns only the
  actor's rows, and a revocation naming someone else's jti updates nothing.
  A token row carries no user id, only AshAuthentication's subject string
  (`"user?id=…"`), so the filter is built from the actor the same way the
  library builds the subject it stores.

  Only an `KilnCMS.Accounts.User` actor owns tokens. Anything else — no actor,
  an API key — matches nothing. The struct is compared by module rather than
  matched as a pattern: a struct pattern on a resource named in a policy is a
  compile-time cycle that deadlocks a two-scheduler build.
  """
  use Ash.Policy.FilterCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "the token belongs to the actor"

  @impl Ash.Policy.FilterCheck
  def filter(%{__struct__: module} = actor, _authorizer, _opts)
      when module == KilnCMS.Accounts.User do
    subject = AshAuthentication.user_to_subject(actor)
    expr(subject == ^subject)
  end

  def filter(_actor, _authorizer, _opts), do: expr(false)
end
