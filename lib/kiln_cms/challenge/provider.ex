defmodule KilnCMS.Challenge.Provider do
  @moduledoc """
  A human-verification provider: something that draws a widget in the browser
  and later says whether the token that widget produced is genuine (#2249).

  Core-internal for now. `KilnCMS.Challenge.Providers.Turnstile` is the one built-in, and
  the operator picks a provider by its `id/0` (`CHALLENGE_PROVIDER`). The shape
  is deliberately not in the plugin SDK yet: an SDK callback is a promise kept
  for the whole of 1.x, and this one should be proven by a second provider
  before it is made.

  ## The browser half

  `script_url/0` is loaded once, by the `Challenge` hook in
  `assets/js/challenge.js` (never by an inline script). It must define the
  global named by `global/0`, with the explicit-render API Turnstile and
  reCAPTCHA share: `render(element, options)` returning a widget id,
  `reset(id)` and `remove(id)`, where `options` carries `sitekey`, `action`,
  `callback`, `expired-callback` and `error-callback`.

  `csp_sources/0` lists the origins that script and its frames need. They are
  added to the auth pages' policy only while a challenge can be shown there
  (`KilnCMSWeb.Plugs.ChallengeCsp`).

  ## The server half

  `verify/2` gets the token and these options:

    * `:secret` — the operator's secret key.
    * `:action` — `"sign_in"` or `"register"`, the action the widget was drawn
      for. A provider that reports one must refuse a mismatch.
    * `:hostname?` — a predicate the hostname the provider reports must
      satisfy, or `nil` to skip that check.
    * `:remote_ip` — the client address, present only when the operator turned
      `send_remote_ip` on; send nothing otherwise.
    * `:post` — `fn url, fields -> result end`, the transport
      (`KilnCMS.Challenge.Transport.post_form/3`). A provider never dials out on
      its own: the core owns timeouts, the byte cap and the no-redirect rule.

  It answers `:ok`, `{:error, reason}` for a token that is not good, or
  `{:error, {:unavailable, reason}}` when it could not tell. Only the last may
  ever admit an attempt (`KilnCMS.Challenge.Gate`), so a provider must never
  report an answer it did not get as `:unavailable`'s opposite — and must
  never report a refusal it *did* get as unavailable either.
  """

  @type csp_sources :: %{
          script_src: [String.t()],
          frame_src: [String.t()],
          connect_src: [String.t()]
        }

  @type refusal ::
          :missing
          | :malformed
          | :invalid
          | :expired
          | :hostname_mismatch
          | :action_mismatch

  @type unavailable ::
          :timeout
          | :transport
          | :http_status
          | :malformed_response
          | :not_configured
          | :crashed

  @type result :: :ok | {:error, refusal()} | {:error, {:unavailable, unavailable()}}

  @doc "The id an operator names the provider by (`CHALLENGE_PROVIDER`)."
  @callback id() :: String.t()

  @doc "A human name for logs and the operator."
  @callback label() :: String.t()

  @doc "The script the browser loads, with explicit rendering."
  @callback script_url() :: String.t()

  @doc "The browser global the script defines."
  @callback global() :: String.t()

  @doc "Origins the widget needs in the page's Content-Security-Policy."
  @callback csp_sources() :: csp_sources()

  @doc "Whether `token` is a genuine, unspent answer for this deployment."
  @callback verify(token :: String.t(), opts :: keyword()) :: result()
end
