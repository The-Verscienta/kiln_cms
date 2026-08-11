defmodule KilnCMS.Accounts.ClientIpBudget do
  @moduledoc """
  Charges a per-IP rate bucket from *inside* an Ash action (#715, #724).

  Every credential form on `/sign-in`, `/register` and `/reset` is an
  `AshAuthentication.Phoenix` LiveComponent that calls
  `AshPhoenix.Form.submit/2` **in process**. The credentials therefore arrive as
  a `/live` event and pass no router pipeline at all, so
  `KilnCMSWeb.Plugs.RateLimit` never sees them. #715 established the way round
  that for the sign-in submit: `KilnCMSWeb.SignInLive` resolves the socket's own
  client address from its handshake and puts it in the action's context, and the
  action charges the bucket a plug would have.

  This is that mechanism, extracted, because #715 wired it to exactly one
  action and #724 found the other three unbudgeted. Registration was the sharp
  one: one websocket replaying `submit` is unlimited account creation, a bcrypt
  hash and a confirmation mail per event, from one address, with nothing
  counting.

  ## Only when the caller put an address there

  A missing address means "a plug already charged this" — every HTTP entry
  point pays `KilnCMSWeb.Plugs.RateLimit` on the way in. Charging
  unconditionally would bill those twice, halving a limit the threat model
  states as one number. So the context key is the whole signal, and
  `KilnCMSWeb.SignInLive` is the only thing that writes it.

  ## The charge belongs in a hook, not in the callback body

  `prepare/3` and `change/3` run when the query or changeset is **built**, and
  `AshPhoenix.Form.validate/2` builds one per keystroke — the forms are
  `phx-change="change"`. A charge there spends a budget per character typed, so
  a user picking a twenty-character password locks themselves out before they
  can submit it. Every caller here charges from `before_action`, which runs once
  when the action actually executes. That is the bug #478 shipped live, one
  layer up.
  """

  alias KilnCMS.Accounts.Preparations.ThrottleSignIn

  @doc """
  The bucket refusal, or `:allow` — including when there is no address in
  `context`, which means a router pipeline already charged this request.

  `bucket` is a key of `KilnCMSWeb.RateLimit`'s limits.
  """
  @spec check(map(), atom()) :: :allow | {:deny, non_neg_integer()}
  def check(context, bucket) when is_map(context) and is_atom(bucket) do
    case Map.get(context, ThrottleSignIn.context_key()) do
      ip when is_binary(ip) -> KilnCMSWeb.RateLimit.check(bucket, ip)
      _absent -> :allow
    end
  end

  @doc """
  The `AuthenticationFailed` a refused credential form answers with.

  The same error a wrong password produces, so the caller renders the same
  generic message. A refusal that announced itself would tell an attacker
  exactly which addresses are throttled and when the window rolls.

  Deliberately **without** a simulated bcrypt, unlike the per-account refusal in
  `ThrottleSignIn`. That one must burn one because a fast answer reveals *which
  account* is throttled, which is an enumeration oracle. Here the only thing a
  fast answer reveals is that the caller's own address is out of budget, which
  the caller already knows — they sent the traffic. Paying bcrypt anyway would
  give up most of what a per-IP limit is for: past the ceiling, a flood would
  still cost a full password hash per request.
  """
  @spec refusal(module(), atom()) :: Exception.t()
  def refusal(module, action) do
    AshAuthentication.Errors.AuthenticationFailed.exception(
      caused_by: %{
        module: module,
        action: action,
        message: "Too many requests from this address"
      }
    )
  end
end
