defmodule KilnCMS.OEmbed.Provider do
  @moduledoc """
  The curated oEmbed provider list (#489).

  ## A registry, not discovery

  The oEmbed spec has a discovery mechanism: fetch the page, read a
  `<link rel="alternate" type="application/json+oembed">`, fetch *that*. Kiln
  does not use it, and that is the security decision this module exists to
  encode.

  Discovery makes the *content* choose which host the server talks to, and the
  URL in an embed block is typed by whoever can edit a page. `KilnCMS.SafeFetch`
  stops that reaching a private address, but it cannot stop it reaching an
  arbitrary public one — so discovery turns "editor" into "can make this server
  issue requests anywhere, with its egress IP". A fixed list means an editor
  chooses among endpoints an *operator* approved, and the URL only ever selects
  which of them is asked.

  It also means the failure mode of an unknown URL is the existing bare-URL
  figure rather than a request, which is the right default for a feature that
  is otherwise a network call on every save.

  ## Matching

  Each provider carries `url_patterns` — anchored regexes over the *canonical*
  form of a URL (scheme and `www.` stripped, matching is case-insensitive on the
  host). A pattern that is not anchored at both ends is a bug: `youtube\\.com`
  unanchored matches `evil-youtube.com.attacker.example`.

  `endpoint` is where the metadata is fetched from, and it is a constant per
  provider — never taken from the URL being embedded.

  ## Adding one

  Cheap, and deliberately a code change rather than configuration: a provider is
  a host this server will make outbound requests to, which is a deployment
  decision worth a diff. `config :kiln_cms, KilnCMS.OEmbed, providers: [...]`
  restricts the shipped list further (by name) for a deployment that wants
  fewer; it cannot add to it.
  """

  @type t :: %{
          name: String.t(),
          endpoint: String.t(),
          url_patterns: [Regex.t()]
        }

  # Anchored at both ends, every one. See the moduledoc.
  @providers [
    %{
      name: "YouTube",
      endpoint: "https://www.youtube.com/oembed",
      url_patterns: [~r{^youtube\.com/watch\?.*$}i, ~r{^youtu\.be/[\w-]+$}i]
    },
    %{
      name: "Vimeo",
      endpoint: "https://vimeo.com/api/oembed.json",
      url_patterns: [~r{^vimeo\.com/\d+$}i]
    },
    %{
      name: "SoundCloud",
      endpoint: "https://soundcloud.com/oembed",
      url_patterns: [~r{^soundcloud\.com/[\w-]+/[\w-]+$}i]
    },
    %{
      name: "Spotify",
      endpoint: "https://open.spotify.com/oembed",
      url_patterns: [~r{^open\.spotify\.com/(track|album|playlist|episode|show)/[\w]+$}i]
    },
    %{
      name: "CodePen",
      endpoint: "https://codepen.io/api/oembed",
      url_patterns: [~r{^codepen\.io/[\w-]+/pen/[\w-]+$}i]
    },
    %{
      name: "Flickr",
      endpoint: "https://www.flickr.com/services/oembed/",
      url_patterns: [~r{^flickr\.com/photos/[^/]+/\d+/?$}i, ~r{^flic\.kr/p/[\w]+$}i]
    },
    %{
      name: "TED",
      endpoint: "https://www.ted.com/services/v1/oembed.json",
      url_patterns: [~r{^ted\.com/talks/[\w-]+$}i]
    },
    %{
      name: "Bluesky",
      endpoint: "https://embed.bsky.app/oembed",
      url_patterns: [~r{^bsky\.app/profile/[^/]+/post/[\w]+$}i]
    }
  ]

  @doc "Every provider this build knows about, before any deployment restriction."
  @spec all() :: [t()]
  def all, do: @providers

  @doc """
  The providers actually enabled here.

  `config :kiln_cms, KilnCMS.OEmbed, providers: ["YouTube", "Vimeo"]` narrows the
  shipped list; an absent or `nil` setting means all of them. Names that match
  nothing are ignored rather than erroring — a typo should not take out the
  providers that *are* spelled right, and the whole feature degrades to the
  bare-URL figure anyway.
  """
  @spec enabled() :: [t()]
  def enabled do
    case Application.get_env(:kiln_cms, KilnCMS.OEmbed, [])[:providers] do
      nil -> @providers
      names when is_list(names) -> Enum.filter(@providers, &(&1.name in names))
      _other -> @providers
    end
  end

  @doc """
  The enabled provider that claims `url`, or `nil`.

  Matching is against a canonical form — scheme and a leading `www.` removed —
  so `https://www.youtube.com/watch?v=x` and `youtube.com/watch?v=x` are the
  same URL to the patterns.
  """
  @spec for_url(String.t()) :: t() | nil
  def for_url(url) when is_binary(url) do
    case canonical(url) do
      nil -> nil
      canonical -> Enum.find(enabled(), &matches?(&1, canonical))
    end
  end

  def for_url(_url), do: nil

  @doc """
  Hosts whose images a rendered card may load — for the delivery CSP's
  `img-src`, and for the resolver's own check on a returned thumbnail URL.

  Empty when oEmbed is switched off, so a deployment that never resolves an
  embed never widens its policy either.
  """
  @spec thumbnail_hosts() :: [String.t()]
  def thumbnail_hosts do
    if KilnCMS.OEmbed.enabled?() do
      for provider <- enabled(), host <- hosts_for(provider.name), uniq: true, do: host
    else
      []
    end
  end

  @doc "The thumbnail CDN hosts of one provider."
  @spec thumbnail_hosts(t()) :: [String.t()]
  def thumbnail_hosts(%{name: name}), do: hosts_for(name)

  # Thumbnail CDNs are a different set of hosts from the oEmbed endpoints, and
  # they are not derivable from them. Listed rather than inferred, because
  # `img-src` is a security boundary and "whatever the provider returned" is not
  # a boundary at all — a provider whose response is compromised, or simply
  # generous, could otherwise point the browser anywhere.
  defp hosts_for("YouTube"), do: ["https://i.ytimg.com", "https://img.youtube.com"]
  defp hosts_for("Vimeo"), do: ["https://i.vimeocdn.com"]
  defp hosts_for("SoundCloud"), do: ["https://i1.sndcdn.com"]
  defp hosts_for("Spotify"), do: ["https://i.scdn.co"]
  defp hosts_for("CodePen"), do: ["https://shots.codepen.io"]
  defp hosts_for("Flickr"), do: ["https://live.staticflickr.com"]

  defp hosts_for("TED"),
    do: ["https://pi.tedcdn.com", "https://talkstar-photos.s3.amazonaws.com"]

  defp hosts_for("Bluesky"), do: ["https://cdn.bsky.app"]
  defp hosts_for(_name), do: []

  defp matches?(provider, canonical),
    do: Enum.any?(provider.url_patterns, &Regex.match?(&1, canonical))

  defp canonical(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        host = host |> String.downcase() |> String.replace_prefix("www.", "")
        path = String.trim_trailing(uri.path || "", "/")
        query = if uri.query, do: "?" <> uri.query, else: ""
        host <> path <> query

      _other ->
        nil
    end
  end
end
