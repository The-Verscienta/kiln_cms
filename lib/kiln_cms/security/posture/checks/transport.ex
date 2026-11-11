defmodule KilnCMS.Security.Posture.Checks.Transport do
  @moduledoc """
  `core.transport` (#2252): on a production build, whether every request is
  pushed to HTTPS with HSTS, the public URL is `https`, and the session cookie
  is `Secure`.

  Reads what the running endpoint was built with, not the config files:
  `force_ssl` (and its `:hsts`, on unless set `false`) and `url` from
  `KilnCMSWeb.Endpoint.config/1`, and `Secure` from the session options the
  endpoint compiled into its `Plug.Session`. Any one off
  fails. On any other build it is `:n_a`: development and test serve plain
  HTTP on purpose.

  `assess/1` judges a map of those values, so a test can flip one of them
  without rebuilding the endpoint.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Security.Posture

  @impl Kiln.Security.Check
  def id, do: "core.transport"

  @impl Kiln.Security.Check
  def title, do: gettext("HTTPS and secure cookies")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "Without HTTPS everywhere, a session cookie can be read off the network and replayed."
      )

  @impl Kiln.Security.Check
  def scope, do: :deployment

  @impl Kiln.Security.Check
  def run(%{build_env: :prod}) do
    assess(%{
      force_ssl: KilnCMSWeb.Endpoint.config(:force_ssl),
      url: KilnCMSWeb.Endpoint.config(:url),
      session_options: KilnCMSWeb.Endpoint.session_options()
    })
  end

  def run(%{build_env: env}) do
    n_a(gettext("Only checked on production builds; this is a %{env} build.", env: env))
  end

  @doc false
  # The judgement, apart from where the values come from (see the moduledoc).
  @spec assess(%{force_ssl: term(), url: term(), session_options: keyword()}) ::
          Kiln.Security.Check.Result.t()
  def assess(%{force_ssl: force_ssl, url: url, session_options: session_options}) do
    force_ssl? = is_list(force_ssl) or force_ssl == true

    hsts? =
      force_ssl? and (not is_list(force_ssl) or Keyword.get(force_ssl, :hsts, true) != false)

    https? = is_list(url) and to_string(Keyword.get(url, :scheme)) == "https"
    secure? = Keyword.get(session_options, :secure) == true

    problems =
      [
        {force_ssl?, gettext("Plain HTTP requests are not redirected to HTTPS (force_ssl).")},
        {hsts?, gettext("Browsers are not told to insist on HTTPS (HSTS).")},
        {https?, gettext("The public URL is not https.")},
        {secure?, gettext("The session cookie is not marked Secure.")}
      ]
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    opts = [
      details: problems,
      docs_url: Posture.docs_url("https-and-secure-cookies"),
      facts: %{force_ssl: force_ssl?, hsts: hsts?, https_url: https?, secure_cookie: secure?}
    ]

    if problems == [],
      do: pass(gettext("HTTPS is enforced, with HSTS and a Secure session cookie."), opts),
      else: fail(gettext("Requests or cookies can travel over plain HTTP."), opts)
  end
end
