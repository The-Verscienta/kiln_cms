defmodule KilnCMSWeb.Embed do
  @moduledoc """
  Framing policy for **embeddable forms** (`GET /forms/:slug/embed`).

  The embed page is a self-contained document served from the CMS origin and
  designed to be iframed on third-party sites. The site-wide CSP pins
  `frame-ancestors 'self'`, which would block exactly that, so the embed route
  serves its own policy built here.

  Which parents may frame it comes from `:embed_origins` config, resolved **per
  request** so `EMBED_ORIGINS` can be set at runtime (see `config/runtime.exs`):

    * `:all` (the default) — any site may embed the form. Safe because the embed
      page carries **no ambient credentials**: it's an anonymous, public form,
      and a cross-site iframe never receives the `SameSite=Lax` session cookie.
      There is nothing to clickjack — submissions are already unauthenticated and
      bounded by the honeypot plus the `:form` rate bucket.
    * `[origin, …]` — an allowlist of parent origins, e.g.
      `EMBED_ORIGINS=https://acme.com,https://blog.acme.com`.
    * `[]` — same-origin only (`'self'`), i.e. embedding effectively off.

  Scripts on the embed page are external files under `script-src 'self'`
  (`/embed-frame.js`), so no nonce or `unsafe-inline` is needed.
  """

  @doc "The `frame-ancestors` source list for the embed page's CSP."
  @spec frame_ancestors() :: String.t()
  def frame_ancestors do
    case Application.get_env(:kiln_cms, :embed_origins, :all) do
      :all -> "*"
      [] -> "'self'"
      origins when is_list(origins) -> Enum.join(origins, " ")
      _ -> "'self'"
    end
  end

  @doc """
  The full Content-Security-Policy for embed responses (the form page and the
  thank-you page it posts to). Same-origin everything, except `frame-ancestors`.
  """
  @spec content_security_policy() :: String.t()
  def content_security_policy do
    "default-src 'self'; " <>
      "script-src 'self'; " <>
      "style-src 'self' 'unsafe-inline'; " <>
      "img-src 'self' data: blob:; " <>
      "font-src 'self' data:; " <>
      "connect-src 'self'; " <>
      "object-src 'none'; base-uri 'self'; form-action 'self'; " <>
      "frame-ancestors #{frame_ancestors()}"
  end

  @doc """
  Parses an `EMBED_ORIGINS` env value. `"*"` → `:all`; a comma-separated list →
  an allowlist; blank → `[]` (same-origin only).
  """
  @spec parse_env(String.t()) :: :all | [String.t()]
  def parse_env(value) when is_binary(value) do
    case String.trim(value) do
      "*" ->
        :all

      "" ->
        []

      trimmed ->
        trimmed
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end
end
