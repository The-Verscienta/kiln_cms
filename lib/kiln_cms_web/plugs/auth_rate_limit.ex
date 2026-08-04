defmodule KilnCMSWeb.Plugs.AuthRateLimit do
  @moduledoc """
  Charges the auth pipeline's per-IP bucket, picking `:register` for the
  registration POST and `:auth` for everything else (#724).

  Registration has two doors, and until this they disagreed. The LiveView form
  submits over `/live`, passes no pipeline, and is charged `:register` (5/min)
  by `KilnCMS.Accounts.Changes.ThrottleRegistration`. But `auth_routes` also
  generates `POST /auth/user/password/register`, a real route on
  `:browser_auth` — AshAuthentication's non-JS fallback — and that path went
  through `KilnCMSWeb.Plugs.RateLimit, :auth` at **20/min**, four times the
  stated ceiling, while the action's own charge saw no client-IP context and so
  did nothing.

  So a scripted client that fetched a CSRF token from `GET /register` got the
  looser limit *and* spent the **sign-in** bucket doing it — which is precisely
  the coupling `:register` exists to prevent: a burst of sign-ups locking
  sign-in for everyone behind one office NAT.

  `:register` **instead of** `:auth` for that path, not as well as. Charging
  both would leave the coupling in place: the registrations would still fill
  the sign-in bucket, and the tighter limit would only decide which of the two
  refused first.

  ## Why a plug rather than the action's own charge

  The action charges only when the caller put a client address in its context,
  and only `KilnCMSWeb.SignInLive` does — that key is what distinguishes "no
  plug could reach this" from "a plug already charged it". Setting the context
  here instead would double-charge every HTTP sign-in, halving a limit the
  threat model states as one number. So the two doors are charged by two
  mechanisms that agree on the bucket rather than by one that cannot tell them
  apart.
  """
  @register_action "register"

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    KilnCMSWeb.Plugs.RateLimit.call(conn, bucket(conn))
  end

  # `auth_routes` mounts these as `/auth/<subject>/<strategy>/<action>`, so the
  # last segment names the action. Matched on the segment rather than the whole
  # path because the subject and strategy names are configurable.
  defp bucket(%{method: "POST", path_info: path_info}) do
    if List.last(path_info) == @register_action, do: :register, else: :auth
  end

  defp bucket(_conn), do: :auth
end
