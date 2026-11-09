defmodule KilnCMSWeb.Plugs.SecurityContext do
  @moduledoc """
  Hands the request's facts to the Ash actions a sign-in runs (#2241).

  `AshAuthentication`'s plugs call the strategy's action with
  `Ash.PlugHelpers.get_context/1`, so adding the client address, user agent and
  org here is how the sign-in action's audit hook
  (`KilnCMS.Security.Preparations.AuditSignIn`) knows whose log the event is
  for and where the request came from. Nothing else reads it: the context does
  not change what the action does, only what it reports.

  It also names the door for human verification (#2249): these are the browser
  doors, so `KilnCMS.Challenge.Gate` applies the operator's sign-in and
  registration modes to them. (Not the request's host: a `Host` header is the
  caller's to choose, so it never vouches for where a token was solved.)
  """
  @behaviour Plug

  alias KilnCMS.Challenge
  alias KilnCMS.Security.AuthEvents

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    existing = Ash.PlugHelpers.get_context(conn) || %{}

    context =
      existing
      |> Map.merge(AuthEvents.context(conn))
      |> Map.merge(Challenge.context(:browser))

    Ash.PlugHelpers.set_context(conn, context)
  end
end
