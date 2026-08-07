defmodule KilnCMS.Federation.Actor do
  @moduledoc """
  A site's ActivityPub identity: the URLs it is known by, and the actor
  document it serves (#491).

  Every URL here derives from the settings row's **pinned** `origin`, never
  from the request or from `KilnCMSWeb.Tenant.base_url/1`. An actor id is a
  permanent name — see `KilnCMS.Federation.SiteFederation` on why deriving it
  per-request would orphan followers the day a `custom_domain` is added.
  """

  alias KilnCMS.Federation.SiteFederation

  @typedoc "The URL set a site's actor is addressed by."
  @type identity :: %{
          origin: String.t(),
          username: String.t(),
          handle: String.t(),
          subject: String.t(),
          actor_id: String.t(),
          key_id: String.t(),
          inbox: String.t(),
          outbox: String.t(),
          followers: String.t()
        }

  @doc """
  The URL set for a settings row.

  A single fixed actor per site (`/actor`) rather than Mastodon's
  `/users/:name`: a Kiln site is one publication, not a user directory, and a
  fixed path cannot be shadowed by a content type whose plural happens to
  collide.
  """
  @spec identity(SiteFederation.t()) :: identity()
  def identity(%{origin: origin, username: username})
      when is_binary(origin) and is_binary(username) do
    actor_id = origin <> "/actor"

    %{
      origin: origin,
      username: username,
      handle: "@#{username}@#{host(origin)}",
      subject: "acct:#{username}@#{host(origin)}",
      actor_id: actor_id,
      key_id: actor_id <> "#main-key",
      inbox: actor_id <> "/inbox",
      outbox: actor_id <> "/outbox",
      followers: actor_id <> "/followers"
    }
  end

  @doc """
  The `Person`-style actor document.

  Typed `Service`, not `Person`: this is a publication that posts automatically,
  and Mastodon renders `Service` actors with a bot marker. Saying so is more
  honest than the extra reach `Person` would buy, and mislabelling automated
  accounts is the thing instance moderators block for.
  """
  @spec document(SiteFederation.t()) :: map()
  def document(%SiteFederation{} = settings) do
    id = identity(settings)

    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1"
      ],
      "id" => id.actor_id,
      "type" => "Service",
      "preferredUsername" => id.username,
      "name" => settings.display_name || id.username,
      "inbox" => id.inbox,
      "outbox" => id.outbox,
      "followers" => id.followers,
      "url" => id.origin,
      "manuallyApprovesFollowers" => false,
      # Phase 1 is read-only, and a discoverable actor with no inbound handling
      # beyond Follow is exactly what this is. `discoverable` opts into
      # directory listing; `indexable` is Mastodon's search opt-in.
      "discoverable" => true,
      "indexable" => true,
      "publicKey" => %{
        "id" => id.key_id,
        "owner" => id.actor_id,
        "publicKeyPem" => settings.public_key_pem
      }
    }
    |> put_present("summary", settings.summary)
  end

  @doc """
  The WebFinger JRD for a site — what `acct:<user>@<host>` resolves to.

  The `self` link with `application/activity+json` is the one that matters: it
  is how a remote server gets from a typed `@handle` to the actor document.
  """
  @spec webfinger(SiteFederation.t()) :: map()
  def webfinger(%SiteFederation{} = settings) do
    id = identity(settings)

    %{
      "subject" => id.subject,
      "aliases" => [id.actor_id],
      "links" => [
        %{
          "rel" => "self",
          "type" => "application/activity+json",
          "href" => id.actor_id
        },
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => id.origin
        }
      ]
    }
  end

  @doc """
  Whether `resource` names this site's actor.

  Compared case-insensitively on the host, and both `acct:user@host` and a bare
  `user@host` are accepted — Mastodon sends the former, some clients the
  latter. The actor URL itself is accepted too, which is what a server that
  already knows the id sends when confirming a handle.
  """
  @spec matches_resource?(SiteFederation.t(), String.t()) :: boolean()
  def matches_resource?(%SiteFederation{} = settings, resource) when is_binary(resource) do
    id = identity(settings)
    normalized = resource |> String.trim() |> String.downcase()

    normalized in [
      String.downcase(id.subject),
      String.downcase(id.subject) |> String.replace_prefix("acct:", ""),
      String.downcase(id.actor_id)
    ]
  end

  def matches_resource?(_settings, _resource), do: false

  @doc "The host half of a pinned origin, port included when non-default."
  @spec host(String.t()) :: String.t()
  def host(origin) do
    uri = URI.parse(origin)
    default_port = if uri.scheme == "https", do: 443, else: 80

    if uri.port in [nil, default_port], do: uri.host, else: "#{uri.host}:#{uri.port}"
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
