defmodule KilnCMS.OEmbed do
  @moduledoc """
  Server-side oEmbed metadata for the `embed` block (#489).

  An embed block used to store a URL and render `<figure data-url="…">` — no
  title, no thumbnail, no provider. A headless consumer got a naked URL and had
  to decide what to do with it, which in practice meant nothing was rendered at
  all.

  This resolves a URL against the curated provider list
  (`KilnCMS.OEmbed.Provider`) and returns the card fields: title, author,
  provider name, thumbnail. It is deliberately **not** on the render path — see
  below.

  ## Resolved once, stored on the block

  A network call per render is a network call per page view, on the delivery
  path, with the provider's availability in front of the site's. So resolution
  happens when the URL is set (the editor resolves as you paste, and the save
  carries the result), the metadata is stored on the block like any other field,
  and rendering is pure.

  That makes staleness the trade: a video renamed after publication keeps its old
  title until something re-resolves it. Re-firing is the natural moment, and the
  block records `resolved_at` so a refresh can tell what is old.

  ## What is kept, and what is thrown away

  oEmbed responses carry an `html` field — a provider-authored iframe or script
  tag. Kiln **discards it**. Rendering provider HTML means either trusting a
  third party with script execution on the delivery origin, or maintaining a
  sanitizer for markup whose whole purpose is to do things sanitizers strip.
  Neither is worth a nicer card.

  What ships instead is a **link, a thumbnail and a title** — built from scalar
  fields, escaped like any other content. The two hosts that already had a
  canonical-iframe rewrite (`KilnCMS.HTMLSanitizer.safe_embed_url/1`) keep it;
  that allowlist is unchanged and remains the only thing that produces an
  `<iframe>`.

  Thumbnail URLs are checked against the provider's known CDN hosts rather than
  taken on trust: `img-src` is a security boundary, and a compromised or merely
  generous provider response should not be able to point the browser anywhere.

  ## Egress, and why this is off by default

  Enabling this makes the server issue outbound requests on content edits. Some
  deployments cannot do that, and none should have it happen without saying so.
  `enabled?/0` is false unless configured:

      config :kiln_cms, KilnCMS.OEmbed, enabled: true

  Requests go through `KilnCMS.SafeFetch` (address-pinned, size-capped,
  no redirects) even though every endpoint is a constant from the provider list.
  Belt and braces: the list is a compile-time constant today, but a provider's
  DNS is not, and "the endpoint is hardcoded" is exactly the assumption that
  makes a later `providers:` config change quietly dangerous.
  """

  alias KilnCMS.OEmbed.Provider
  alias KilnCMS.SafeFetch

  require Logger

  # oEmbed responses are small JSON documents. 64KB is generous for one; a
  # provider streaming more than that is not answering the question asked.
  @max_bytes 64 * 1024

  @type metadata :: %{
          optional(:title) => String.t(),
          optional(:author_name) => String.t(),
          optional(:provider_name) => String.t(),
          optional(:thumbnail_url) => String.t()
        }

  @doc "Whether oEmbed resolution is switched on for this deployment."
  @spec enabled?() :: boolean()
  def enabled?, do: config()[:enabled] == true

  @doc """
  Whether an enabled provider would claim `url` — i.e. whether resolving it is
  worth a request at all. Cheap and offline; the save path uses it to decide
  whether to enqueue anything.
  """
  @spec resolvable?(term()) :: boolean()
  def resolvable?(url), do: enabled?() and not is_nil(Provider.for_url(url))

  @doc """
  Resolve `url` to card metadata.

  `{:ok, metadata}`, or `{:error, reason}` when the feature is off, no enabled
  provider claims the URL, or the fetch fails. Every error is a reason to fall
  back to the bare-URL figure — there is no failure here that should stop a save.
  """
  @spec resolve(String.t()) :: {:ok, metadata()} | {:error, atom() | String.t()}
  def resolve(url) when is_binary(url) do
    cond do
      not enabled?() -> {:error, :disabled}
      provider = Provider.for_url(url) -> fetch(provider, url)
      true -> {:error, :no_provider}
    end
  end

  def resolve(_url), do: {:error, :no_provider}

  defp fetch(provider, url) do
    endpoint = provider.endpoint <> "?" <> URI.encode_query(%{"url" => url, "format" => "json"})

    case SafeFetch.get(endpoint,
           max_bytes: @max_bytes,
           headers: [{"accept", "application/json"}],
           req_options: req_options()
         ) do
      {:ok, %{status: 200, body: body}} ->
        decode(provider, body)

      {:ok, %{status: status}} ->
        {:error, "provider returned HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(provider, body) do
    case Jason.decode(body) do
      {:ok, %{} = payload} -> {:ok, card(provider, payload)}
      _other -> {:error, "provider returned a non-JSON body"}
    end
  end

  # Scalars only. `html`, `width`, `height` and everything else the response
  # carries are dropped on the floor — see the moduledoc on why the provider's
  # markup never renders.
  defp card(provider, payload) do
    %{
      title: string(payload["title"]),
      author_name: string(payload["author_name"]),
      # The provider's own name is preferred, but ours is the fallback rather
      # than nil: the card's "on <provider>" line should never be blank for a
      # provider we matched by name a moment ago.
      provider_name: string(payload["provider_name"]) || provider.name,
      thumbnail_url: thumbnail(provider, payload["thumbnail_url"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp thumbnail(provider, url) do
    case allowed_thumbnail(url, provider) do
      nil ->
        Logger.debug("oembed: dropped an off-CDN thumbnail from #{provider.name}")
        nil

      allowed ->
        allowed
    end
  end

  @doc """
  `url` if it is on an enabled provider's thumbnail CDN, otherwise `nil`.

  A thumbnail is a URL the browser is told to load, so it is checked rather than
  trusted — a compromised or merely generous provider response must not be able
  to point every reader's browser at an arbitrary host.

  Public because the *write* path needs the same check: these are ordinary block
  scalars, so an editor or a headless caller can set `thumbnail_url` to whatever
  they like, and a value that never came from a resolve would otherwise reach
  `<img src>` unfiltered (see the embed clause in `KilnCMS.CMS.TypedBlocks`).

  The port is compared too. A portless CSP host-source matches the default port
  only, so accepting `https://i.ytimg.com:8080/x.jpg` here would store a URL
  `img-src` then blocks — a picture that silently never loads.
  """
  @spec allowed_thumbnail(term(), Provider.t() | nil) :: String.t() | nil
  def allowed_thumbnail(url, provider \\ nil)

  def allowed_thumbnail(url, provider) when is_binary(url) do
    # The matched provider's own hosts when we know it (a resolve), the union of
    # every enabled provider's when we do not (a write, where the block names no
    # provider). Narrower is better where it is available: a compromised Bluesky
    # response should not be able to claim a YouTube CDN.
    allowed =
      if provider, do: Provider.thumbnail_hosts(provider), else: Provider.thumbnail_hosts()

    trimmed = String.trim(url)

    with %URI{scheme: "https", host: host, port: 443, userinfo: nil} <- URI.parse(trimmed),
         true <- is_binary(host),
         true <- ("https://" <> String.downcase(host)) in allowed do
      trimmed
    else
      _other -> nil
    end
  end

  def allowed_thumbnail(_url, _provider), do: nil

  defp string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 300)
    end
  end

  defp string(_value), do: nil

  defp req_options, do: Keyword.get(config(), :req_options, [])
  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
