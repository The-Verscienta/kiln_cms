defmodule KilnCMS.Challenge.Providers.Recaptcha do
  @moduledoc """
  Google reCAPTCHA v2, the "I'm not a robot" checkbox (#2249), a built-in
  human-verification provider (`CHALLENGE_PROVIDER=recaptcha`).

  Turnstile (`KilnCMS.Challenge.Providers.Turnstile`) is recommended. Choose
  this one when a deployment already holds reCAPTCHA keys or cannot use
  Cloudflare. What it costs:

    * **People click.** v2 shows a checkbox, and sometimes an image puzzle.
      Its widget is `interactive`, so a public form asks the visitor to
      complete it before sending rather than waiting for it.
    * **A wider page policy.** The script, `api.js`, is loaded from
      `www.recaptcha.net` and pulls its code from `www.gstatic.com`, so
      `script-src` gains `https://www.recaptcha.net/recaptcha/` and
      `https://www.gstatic.com/recaptcha/` and `frame-src` gains
      `https://www.recaptcha.net/recaptcha/`. Never `www.google.com`, which
      also serves JSONP endpoints that would let an injected script round a
      strict policy. Verification goes to `www.recaptcha.net` too, so an
      egress allowlist needs one host.
    * **No action binding.** v2 tokens do not carry the action the widget was
      drawn for, so a token solved for one Kiln form can be spent once on
      another of this deployment's checks within its two-minute life. The
      hostname is still checked.

  ## v2 only

  The keys must be v2 checkbox keys. An answer that carries a `score` — a v3
  or Enterprise key — is refused as `:invalid` rather than admitted on a
  threshold Kiln would have to guess (`KilnCMS.Challenge.Siteverify`).

  ## A wrong secret looks like a refused token

  Google answers a wrong secret key with `invalid-input-response`, not
  `invalid-input-secret` (checked against the live endpoint, #2249). Kiln
  therefore reads it as a refused token (`:invalid`), not as the provider
  being misconfigured: nobody is admitted, every check fails, and the
  "could not use its secret key" log line never appears. When every reCAPTCHA
  check fails, check `CHALLENGE_SECRET_KEY` first.

  ## Testing it

  Google's published test **secret** still answers `success: true` with the
  hostname `testkey.google.com`, so add that to `CHALLENGE_HOSTNAMES` while
  using it. Its published test **site key**, though, now renders "Invalid
  site key" in the widget (on Google's side, from `www.google.com` as well),
  so a token cannot be produced with it. To try the widget end to end, use a
  real v2 checkbox key registered for the development hostname.

  Checked in a real browser against the development server: the widget on
  `/sign-in`, `/register`, a form's page and its embed raised no
  Content-Security-Policy violation on the page with the sources below.
  """
  use Kiln.Challenge.Provider

  alias KilnCMS.Challenge.Siteverify

  @origin "https://www.recaptcha.net"
  @verify_url @origin <> "/recaptcha/api/siteverify"

  @impl true
  def id, do: "recaptcha"

  @impl true
  def label, do: "Google reCAPTCHA v2"

  # reCAPTCHA has no `remove/1`: a widget LiveView replaces stays registered in
  # the script's own bookkeeping until the page unloads. Harmless — its element
  # is gone — and there is no API to do better.
  @impl true
  def widget,
    do: %{
      script_url: @origin <> "/recaptcha/api.js?render=explicit",
      global: "grecaptcha",
      # `render=explicit` defines `grecaptcha` before it can render; only the
      # onload callback says it is ready.
      onload_param: "onload",
      response_field: "g-recaptcha-response",
      interactive: true
    }

  @impl true
  def csp_sources,
    do: %{
      script_src: [@origin <> "/recaptcha/", "https://www.gstatic.com/recaptcha/"],
      frame_src: [@origin <> "/recaptcha/"],
      connect_src: []
    }

  @impl true
  def verify(token, opts), do: Siteverify.verify(@verify_url, token, opts, reject_score: true)
end
