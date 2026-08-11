defmodule KilnCMS.Federation.RemoteActor do
  @moduledoc """
  Fetches a remote actor document — the inbox to deliver to, and the key to
  verify its requests with (#491).

  Every fetch goes through `KilnCMS.SafeFetch`, which is the whole reason this
  is a module rather than three lines inline: the URL comes from an inbound
  request written by a stranger, so it is exactly the shape of input SSRF
  protection exists for. An unguarded `Req.get` on a `keyId` would let anyone
  make this server fetch its own cloud metadata endpoint by sending a `Follow`.

  ## The document's `id` must be the URL it came from

  An actor document declares its own `id`, and that string is what every
  downstream check keys on — which follower row to write, whose key may sign
  for it. Believing it unconditionally is a takeover: an attacker serves
  `https://evil.test/a` claiming `"id": "https://mastodon.social/users/victim"`
  with their own `publicKeyPem`, signs a `Follow` with their own key, and the
  upsert overwrites the real victim's follower row — redirecting every future
  delivery to the attacker's inbox. A follow-up `Undo` deletes the real one.

  So `fetch/1` requires the document's `id` to equal the URL it was fetched
  from, and **does not follow redirects**: a redirect would reintroduce the
  same gap, since the check could only compare against one of the two URLs.
  `activity["actor"]` is a canonical actor id in practice, so there is nothing
  to follow.

  ## Successful fetches are cached

  The inbox has to fetch before it can authenticate — the key that verifies the
  signature is *in* the document — so every inbound activity that needs an actor
  costs an outbound request to a host a stranger named, and repeats were not
  deduped (#966). A short-lived cache turns a burst from one actor into one
  fetch.

  Three things it deliberately does not do:

    * **cache a failure.** A 500 or a timeout is transient, and remembering it
      would keep a legitimate actor unreachable for the whole TTL.
    * **live long.** An actor rotating its key is invisible to us until the
      entry expires, and during that window every signature it sends fails to
      verify. Minutes, not hours — long enough to collapse a burst, short enough
      that a rotation is a blip rather than an outage.
    * **grow without bound.** The key is a URL from an unauthenticated request,
      so the entry count is otherwise attacker-chosen. The instance is capped
      and evicts least-recently-written, so filling it costs the attacker one
      fetch per entry and costs this node a fixed table.

  The cache is not per-org. An actor document is a public document about a
  stranger, identical whichever site was asked to fetch it, and the key is the
  canonical URL whole — never a URL joined to anything else, which is how a
  cache key stops being one-to-one.
  """
  import Cachex.Spec, only: [hook: 1]

  @accept "application/activity+json, application/ld+json"
  @max_bytes 128 * 1024

  @cache :kiln_cms_remote_actors

  # A parsed actor document is a handful of strings, so this cap is a few MB. It
  # is a ceiling on abuse, not a working-set target: a site with real federation
  # traffic talks to far fewer distinct actors than this.
  @max_entries 5_000

  # Passed as `expire:`, NOT `ttl:` — Cachex silently ignores unknown options,
  # so `ttl:` compiles, runs, and leaves the entry immortal. That is the trap
  # `KilnCMS.Search.VectorCache` and `KilnCMS.Firing.Cache` both document, and
  # here an immortal entry would pin a rotated key forever.
  @ttl :timer.minutes(10)

  @doc "The Cachex instance name (started in the application supervision tree)."
  @spec cache_name() :: atom()
  def cache_name, do: @cache

  @doc "Supervisor child spec, bounded by an evented least-recently-written policy."
  def child_spec(_arg) do
    Supervisor.child_spec(
      {Cachex,
       name: @cache,
       hooks: [hook(module: Cachex.Limit.Evented, args: {@max_entries, [reclaim: 0.1]})]},
      id: __MODULE__
    )
  end

  @typedoc "What we need from a remote actor to talk to it."
  @type t :: %{
          id: String.t(),
          inbox: String.t(),
          shared_inbox: String.t() | nil,
          public_key_pem: String.t() | nil
        }

  @doc """
  Fetch and parse the actor document at `uri`.

  A `keyId` carries a fragment (`https://host/users/x#main-key`) that resolves
  to the actor document itself, which is where the key lives — so the fragment
  is dropped before fetching.
  """
  @spec fetch(String.t()) :: {:ok, t()} | {:error, String.t()}
  def fetch(uri) when is_binary(uri) do
    canonical = strip_fragment(uri)

    case Cachex.fetch(@cache, canonical, fn _key -> commit(canonical) end) do
      {:ok, cached} -> cached
      {:commit, cached} -> cached
      # `:ignore` carries the error the fetch produced, uncached — see `commit/1`.
      {:ignore, error} -> error
      # The instance is genuinely not running (a release that starts the inbox
      # without the cache, a test). A cache that is down must not take
      # federation down with it.
      {:error, :no_cache} -> fetch_now(canonical)
      # Anything else means the fallback ran and raised, and Cachex's Courier
      # reports it here. Re-fetching would pay a second outbound request for the
      # same failure.
      {:error, _ran_and_failed} -> {:error, "actor fetch failed"}
    end
  end

  def fetch(_uri), do: {:error, "actor uri must be a string"}

  # `:ignore` rather than committing the error. A committed `{:error, _}` would
  # occupy one of the capped entries and, unlike a `nil` (which `Cachex.fetch/3`
  # re-runs the fallback for), it would actually be served — so one bad minute
  # at the far end would be remembered as a bad ten.
  defp commit(canonical) do
    case fetch_now(canonical) do
      {:ok, _actor} = ok -> {:commit, ok, expire: @ttl}
      {:error, _reason} = error -> {:ignore, error}
    end
  end

  defp fetch_now(canonical) do
    with {:ok, %{status: status, body: body}} when status in 200..299 <-
           KilnCMS.SafeFetch.get(canonical,
             headers: [{"accept", @accept}],
             max_bytes: @max_bytes,
             # Deliberately 0 — see the moduledoc. Following a redirect would
             # leave nothing to bind the document's self-declared `id` to.
             max_redirects: 0,
             req_options: KilnCMS.Federation.req_options()
           ),
         {:ok, document} <- Jason.decode(body),
         {:ok, actor} <- parse(document),
         :ok <- same_url(actor.id, canonical) do
      {:ok, actor}
    else
      {:ok, %{status: status}} ->
        {:error, "actor fetch answered #{status}"}

      # Before the generic clause, not after: a decode failure is an
      # `{:error, %Jason.DecodeError{}}`, and `to_string/1` on that struct
      # raises rather than describing it.
      {:error, %Jason.DecodeError{}} ->
        {:error, "actor document was not valid JSON"}

      # `SafeFetch`, `parse/1` and `same_url/2` all return a binary reason, so
      # there is nothing else to coerce.
      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  # The document may only speak for the URL it was served from.
  defp same_url(id, canonical) do
    if strip_fragment(id) == canonical,
      do: :ok,
      else: {:error, "actor document claims an id it was not served from"}
  end

  @doc "Parse an already-fetched actor document."
  @spec parse(map()) :: {:ok, t()} | {:error, String.t()}
  def parse(%{"id" => id, "inbox" => inbox} = document)
      when is_binary(id) and is_binary(inbox) do
    {:ok,
     %{
       id: id,
       inbox: inbox,
       shared_inbox: shared_inbox(document),
       public_key_pem: public_key_pem(document)
     }}
  end

  def parse(_document), do: {:error, "actor document has no id or inbox"}

  @doc """
  Whether `key_id` belongs to `actor`.

  A signature naming someone else's key is the obvious forgery: without this
  check anyone could sign a `Follow` with their own key while claiming to be a
  popular account, and the follow would be recorded against that account.

  The **host** is compared as well as the full URL. `fetch/1` already binds the
  document's `id` to the URL it came from, so an exact match is the real check;
  the host comparison is what keeps that property from resting on one equality
  if the id ever gains a normalized form.
  """
  @spec owns_key?(t(), String.t()) :: boolean()
  def owns_key?(%{id: id}, key_id) when is_binary(key_id) do
    strip_fragment(key_id) == strip_fragment(id) and same_host?(key_id, id)
  end

  def owns_key?(_actor, _key_id), do: false

  @doc "Whether two URLs share a scheme, host and port."
  @spec same_host?(String.t(), String.t()) :: boolean()
  def same_host?(a, b) when is_binary(a) and is_binary(b) do
    left = URI.parse(a)
    right = URI.parse(b)

    not is_nil(left.host) and
      {left.scheme, left.host, left.port} == {right.scheme, right.host, right.port}
  end

  def same_host?(_a, _b), do: false

  defp shared_inbox(%{"endpoints" => %{"sharedInbox" => shared}}) when is_binary(shared),
    do: shared

  defp shared_inbox(_document), do: nil

  defp public_key_pem(%{"publicKey" => %{"publicKeyPem" => pem}}) when is_binary(pem), do: pem

  # Some servers publish `publicKey` as a one-element list.
  defp public_key_pem(%{"publicKey" => [%{"publicKeyPem" => pem} | _rest]}) when is_binary(pem),
    do: pem

  defp public_key_pem(_document), do: nil

  defp strip_fragment(uri), do: uri |> URI.parse() |> Map.put(:fragment, nil) |> URI.to_string()
end
