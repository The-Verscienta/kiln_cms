defmodule KilnCMSWeb.Plugs.SiteStorageCsp do
  @moduledoc """
  Lets a site's pages show the files in its own object storage (#1559).

  A site that brings its own bucket serves its media from that bucket's public
  URL, an origin the operator's `CSP_IMG_SRC` has never heard of — so without
  this, every image the site uploads after switching would be blocked by the
  browser, in the console's media library and on the public site alike. This
  adds the origins of the site's storage profiles
  (`KilnCMS.Storage.SiteProfiles.csp_origins/1`) to the `img-src` and
  `media-src` the `:browser` pipeline's `put_browser_csp` already set.

  Only those two directives, and only for this site's own pages: an image
  origin cannot run anything, and a site admin could already widen its public
  pages' `img-src` through code injection. A site with no profile — nearly all
  of them — gets its response header untouched.

  Directives the policy does not name are left alone rather than added: this
  plug widens a policy, it does not write one.
  """
  @behaviour Plug

  alias KilnCMS.Storage.SiteProfiles

  @directives ["img-src", "media-src"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case conn.assigns[:current_org] do
      %{id: org_id} when is_binary(org_id) -> widen(conn, SiteProfiles.csp_origins(org_id))
      _none -> conn
    end
  end

  defp widen(conn, []), do: conn

  defp widen(conn, origins) do
    case Plug.Conn.get_resp_header(conn, "content-security-policy") do
      [policy | _] ->
        Plug.Conn.put_resp_header(conn, "content-security-policy", widen_policy(policy, origins))

      [] ->
        conn
    end
  end

  @doc false
  # Public for the test: the header is the whole of what this plug does.
  @spec widen_policy(String.t(), [String.t()]) :: String.t()
  def widen_policy(policy, origins) do
    addition = Enum.join(origins, " ")

    policy
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn directive ->
      if Enum.any?(@directives, &(directive == &1 or String.starts_with?(directive, &1 <> " "))),
        do: directive <> " " <> addition,
        else: directive
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
  end
end
