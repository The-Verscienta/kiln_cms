defmodule Kiln.Plugins.Health.Notices do
  @moduledoc """
  Security notices for the plugin health check (#2244), from two sources.

  ## kilncms.dev's feed

  kilncms.dev publishes each advisory as a `security_notice` entry (#1873,
  `scripts/publish/security.exs`), readable through the generic public read
  API every Kiln serves — `GET /api/json/entries/published` with a type filter,
  exactly as `Kiln.Updates` reads the `release` entries. The feed carries
  first-party advisories only (The-Verscienta/kiln_cms and its plugins); for a
  third-party plugin, Hex is the only source.

  `fetch/2` pages at 100 entries and follows `links.next` for at most five
  pages, and only while it stays on the configured URL's origin. A `next`
  pointing elsewhere is not followed (this instance's request does not go to a
  host nobody configured), and a `next` past the fifth page is not either;
  both make the answer `{:error, :truncated}`, since an incomplete list could
  be missing exactly the notice that applies. Requests go through `KilnCMS.SafeFetch` (the
  `next` link is chosen by the far end, and the body is capped at 1 MB) and
  carry the bare `KilnCMS` user-agent, the type filter, field list and page
  size, and nothing about this installation.

  ## Hex

  Hex lists the advisories that affect a release on the release itself
  (`/api/packages/<name>/releases/<version>`, `security_advisories`), so
  `from_hex_release/2` needs no range matching. Withdrawn advisories are
  dropped.
  """

  alias Kiln.Plugins.Health.Notice
  alias KilnCMS.SafeFetch

  @page_size 100
  @max_pages 5
  @max_bytes 1_000_000
  @default_type "security_notice"

  @severities %{
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "critical" => :critical
  }

  # Hex reports CVSS ratings, which include "none".
  @cvss_ratings Map.put(@severities, "none", :low)

  @doc """
  Every `security_notice` entry at `url` (a published-entries endpoint), as
  notices. `{:error, reason}` on any failure: unreachable, refused by
  `KilnCMS.SafeFetch`, a non-200, or a body that is not a JSON:API document.
  A failure is never an empty list.

  Options: `:type` (the content type to filter on, default
  `"#{@default_type}"`) and `:req_options` (a test seam, passed to
  `KilnCMS.SafeFetch`).
  """
  @spec fetch(String.t(), keyword()) :: {:ok, [Notice.t()]} | {:error, term()}
  def fetch(url, opts \\ []) do
    first = with_query(url, Keyword.get(opts, :type, @default_type))

    with {:ok, entries} <- fetch_pages(first, origin(url), @max_pages, [], opts) do
      {:ok, parse_entries(entries)}
    end
  end

  # The configured URL is the endpoint; the query is ours. One the operator
  # wrote is kept in front of it.
  defp with_query(url, type) do
    uri = URI.parse(url)

    query =
      URI.encode_query([
        {"filter[type_name]", type},
        {"fields[entry]", "title,custom_fields"},
        {"page[limit]", @page_size}
      ])

    URI.to_string(%{uri | query: Enum.join(Enum.reject([uri.query, query], &is_nil/1), "&")})
  end

  defp origin(url) do
    uri = URI.parse(url)
    {uri.scheme, uri.host, uri.port}
  end

  # A list cut short is not a list: the pages left unread may be exactly the
  # ones naming an installed plugin, so a `next` this reader will not follow
  # (another origin, or past the page cap) makes the whole answer an error —
  # unknown, never a quiet "no notices". (`Kiln.Updates` can stop early because
  # its newest releases come first; notices have no such order to lean on.)
  defp fetch_pages(url, origin, pages_left, acc, opts) do
    with {:ok, %{"data" => data} = body} <- get(url, opts) do
      acc = acc ++ data

      case next_link(body, origin) do
        :none -> {:ok, acc}
        {:ok, _next} when pages_left <= 1 -> {:error, :truncated}
        {:ok, next} -> fetch_pages(next, origin, pages_left - 1, acc, opts)
        :off_origin -> {:error, :truncated}
      end
    end
  end

  defp next_link(%{"links" => %{"next" => next}}, origin) when is_binary(next) do
    if origin(next) == origin, do: {:ok, next}, else: :off_origin
  end

  defp next_link(_body, _origin), do: :none

  defp get(url, opts) do
    case SafeFetch.get(url,
           headers: [{"accept", "application/vnd.api+json"}, {"user-agent", "KilnCMS"}],
           max_bytes: @max_bytes,
           receive_timeout: 10_000,
           req_options: Keyword.get(opts, :req_options, [])
         ) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"data" => data} = doc} when is_list(data) -> {:ok, doc}
          _other -> {:error, :unparseable}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Notices from a list of JSON:API `security_notice` entries. An entry with no
  `custom_fields.package` names nothing it could be matched against and is
  skipped. Pure.
  """
  @spec parse_entries([map()]) :: [Notice.t()]
  def parse_entries(entries) when is_list(entries), do: Enum.flat_map(entries, &parse_entry/1)

  defp parse_entry(%{"attributes" => %{"custom_fields" => %{"package" => package} = fields}} = e)
       when is_binary(package) do
    case split_packages(package) do
      [] ->
        []

      packages ->
        advisory_id = present(fields["advisory_id"])
        cve_id = present(fields["cve_id"])
        id = advisory_id || cve_id || to_string(e["id"])

        [
          %Notice{
            id: id,
            aliases: Enum.reject([advisory_id, cve_id], &(is_nil(&1) or &1 == id)),
            title: present(get_in(e, ["attributes", "title"])),
            packages: packages,
            affected: present(fields["affected_versions"]),
            patched: present(fields["patched_versions"]),
            severity: Map.get(@severities, downcase(fields["severity"]), :unknown),
            url: http_url(fields["advisory_url"]),
            source: :kiln
          }
        ]
    end
  end

  defp parse_entry(_entry), do: []

  defp split_packages(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  The advisories Hex lists on one release document, for `package`. Withdrawn
  ones are dropped; `cvss_rating` maps to a severity (`none` reads as low, a
  missing rating as unknown). Pure.
  """
  @spec from_hex_release(map(), String.t()) :: [Notice.t()]
  def from_hex_release(%{"security_advisories" => advisories}, package)
      when is_list(advisories) do
    for %{"id" => id} = advisory <- advisories,
        is_binary(id),
        is_nil(advisory["withdrawn_at"]) do
      %Notice{
        id: id,
        aliases: Enum.filter(List.wrap(advisory["aliases"]), &is_binary/1),
        title: present(advisory["summary"]),
        packages: [package],
        affected: advisory["affected"] |> List.wrap() |> Enum.join(" or ") |> present(),
        severity: Map.get(@cvss_ratings, downcase(advisory["cvss_rating"]), :unknown),
        url: http_url(advisory["html_url"]),
        source: :hex
      }
    end
  end

  def from_hex_release(_release, _package), do: []

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp downcase(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp downcase(_value), do: nil

  # The link is someone else's data and ends up as an `href`: http(s) only.
  defp http_url(value) when is_binary(value) do
    case URI.new(String.trim(value)) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ~w(http https) and is_binary(host) and host != "" ->
        String.trim(value)

      _ ->
        nil
    end
  end

  defp http_url(_value), do: nil
end
