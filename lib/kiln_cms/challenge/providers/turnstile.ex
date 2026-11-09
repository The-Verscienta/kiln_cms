defmodule KilnCMS.Challenge.Providers.Turnstile do
  @moduledoc """
  Cloudflare Turnstile (#2249), a built-in human-verification provider and
  the recommended one.

  Recommended over reCAPTCHA (`KilnCMS.Challenge.Providers.Recaptcha`) for
  what it adds to a page's Content-Security-Policy and what it asks of
  people: one origin, `https://challenges.cloudflare.com`, in `script-src`
  and `frame-src`, which serves nothing but the widget; and a check that
  most visitors never have to click.

  ## Verification

  `POST https://challenges.cloudflare.com/turnstile/v0/siteverify` with the
  secret and the token (and the client address only when the operator turned
  `send_remote_ip` on), through `KilnCMS.Challenge.Siteverify`. A pass reports
  the hostname and the action the token was solved for, and the core refuses
  one solved on someone else's page that uses the same site key, or on this
  deployment's form for another purpose (`KilnCMS.Challenge.verify/4`).
  Turnstile always reports the action, so an answer without one is refused.
  """
  use Kiln.Challenge.Provider

  alias KilnCMS.Challenge.Siteverify

  @origin "https://challenges.cloudflare.com"
  @verify_url @origin <> "/turnstile/v0/siteverify"

  @impl true
  def id, do: "turnstile"

  @impl true
  def label, do: "Cloudflare Turnstile"

  @impl true
  def widget,
    do: %{
      script_url: @origin <> "/turnstile/v0/api.js?render=explicit",
      global: "turnstile",
      # Our own hidden input carries the token; Turnstile's default one would
      # post a second copy.
      render_options: %{"response-field" => false},
      action_option: "action",
      response_field: "cf-turnstile-response"
    }

  @impl true
  def csp_sources, do: %{script_src: [@origin], frame_src: [@origin], connect_src: []}

  @impl true
  def verify(token, opts), do: Siteverify.verify(@verify_url, token, opts, require_action: true)
end
