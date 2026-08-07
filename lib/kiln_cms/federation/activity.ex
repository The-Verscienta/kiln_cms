defmodule KilnCMS.Federation.Activity do
  @moduledoc """
  ActivityStreams 2.0 objects and activities built from Kiln content (#491).

  A published document becomes an AS2 `Article` addressed to the public
  collection; publishing, editing and unpublishing become `Create`, `Update`
  and `Delete` wrapping it.

  ## Ids are built from the record id, never the slug

  An AS2 `id` is how every remote server deduplicates. Building it from the
  slug would mean a rename re-announces the same article as a new one to
  everyone who already has it — the same reason the Atom feed uses a stable
  `tag:` URI rather than the page URL. Unlike the feed's, this id must also
  *dereference*, so it is the delivery URL with the record id as a fragment-free
  path: `<origin>/ap/object/<uuid>`.

  ## Content is Markdown-derived, not the raw block tree

  The `:llm` fired surface is already clean chunked Markdown of exactly the
  published content, which is what a Mastodon post wants — the `:web` surface
  is a full HTML document body and would arrive as a wall of markup that most
  clients strip anyway. `content` carries a short HTML rendering (a summary
  paragraph and a link back), and `source` carries the Markdown, which is the
  AS2-sanctioned way to say "here is the original".
  """

  @public "https://www.w3.org/ns/activitystreams#Public"

  @typedoc "What a federated document needs to become an activity."
  @type document :: %{
          required(:id) => String.t(),
          required(:type) => String.t(),
          required(:title) => String.t() | nil,
          required(:url) => String.t(),
          optional(:summary) => String.t() | nil,
          optional(:published_at) => DateTime.t() | nil,
          optional(:updated_at) => DateTime.t() | nil
        }

  @doc "The AS2 public collection every federated object is addressed to."
  @spec public_collection() :: String.t()
  def public_collection, do: @public

  @doc "The dereferenceable AS2 id for a Kiln document under a pinned origin."
  @spec object_id(String.t(), String.t()) :: String.t()
  def object_id(origin, document_id), do: "#{origin}/ap/object/#{document_id}"

  @doc "The AS2 id for one activity about a document — distinct from the object's."
  @spec activity_id(String.t(), String.t(), String.t()) :: String.t()
  def activity_id(origin, document_id, verb),
    do: "#{origin}/ap/activity/#{String.downcase(verb)}/#{document_id}"

  @doc """
  The `Article` object for a document.

  `attributedTo` is the site's actor rather than the human author: the site is
  what a follower followed, and putting an editor's name in a federated object
  publishes staffing information nobody opted into.
  """
  @spec object(map(), map()) :: map()
  def object(document, identity) do
    id = object_id(identity.origin, document.id)

    %{
      "id" => id,
      "type" => "Article",
      "attributedTo" => identity.actor_id,
      "to" => [@public],
      "cc" => [identity.followers],
      "url" => document.url,
      "content" => content_html(document)
    }
    |> put_present("name", document.title)
    |> put_present("summary", document[:summary])
    |> put_present("published", iso8601(document[:published_at]))
    |> put_present("updated", iso8601(document[:updated_at]))
    |> put_source(document[:markdown])
  end

  @doc "A `Create` announcing a newly published document."
  @spec create(map(), map()) :: map()
  def create(document, identity),
    do: wrap("Create", object(document, identity), document, identity)

  @doc "An `Update` announcing an edit to an already-federated document."
  @spec update(map(), map()) :: map()
  def update(document, identity),
    do: wrap("Update", object(document, identity), document, identity)

  @doc """
  A `Delete` withdrawing an unpublished document.

  The object is a bare `Tombstone` rather than the full article: the point is
  that the content is gone, and re-sending it in the activity that says so
  would hand every follower a copy of what was just withdrawn.
  """
  @spec delete(map(), map()) :: map()
  def delete(document, identity) do
    tombstone = %{
      "id" => object_id(identity.origin, document.id),
      "type" => "Tombstone"
    }

    wrap("Delete", tombstone, document, identity)
  end

  @doc """
  An `Accept` of a remote `Follow`, which is what makes the follow stick.

  The echoed `object` is **rebuilt** from four known fields rather than being
  the inbound activity verbatim. Echoing the whole thing would let a caller
  choose the size of what this server then stores for 30 days and POSTs back —
  a megabyte of padding in, a megabyte out, retried. A receiver only needs
  enough to match the Accept to its Follow.
  """
  @spec accept_follow(map(), map()) :: map()
  def accept_follow(follow_activity, identity) do
    echoed =
      %{"type" => "Follow"}
      |> put_present("id", follow_activity["id"])
      |> put_present("actor", follow_activity["actor"])
      |> put_present("object", identity.actor_id)

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{identity.origin}/ap/activity/accept/#{Ash.UUID.generate()}",
      "type" => "Accept",
      "actor" => identity.actor_id,
      "to" => [follow_activity["actor"]],
      "object" => echoed
    }
  end

  @doc """
  An `OrderedCollection` page of activities — the outbox.

  A single page rather than a paginated collection in phase 1. `totalItems` is
  the page's own count, not a table count: claiming a total the collection does
  not enumerate is worse than a smaller honest number.
  """
  @spec outbox([map()], map()) :: map()
  def outbox(activities, identity) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => identity.outbox,
      "type" => "OrderedCollection",
      "totalItems" => length(activities),
      "orderedItems" => activities
    }
  end

  @doc """
  The followers collection.

  Count only, with no `items`: who follows a publication is not the
  publication's information to publish, and Mastodon itself hides follower
  lists by default. The count is what a remote server renders.
  """
  @spec followers_collection(non_neg_integer(), map()) :: map()
  def followers_collection(count, identity) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => identity.followers,
      "type" => "OrderedCollection",
      "totalItems" => count
    }
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp wrap(verb, object, document, identity) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => activity_id(identity.origin, document.id, verb),
      "type" => verb,
      "actor" => identity.actor_id,
      "to" => [@public],
      "cc" => [identity.followers],
      "object" => object
    }
    |> put_present("published", iso8601(document[:published_at]))
  end

  # Deliberately small: a title link plus the summary. A federated post is a
  # pointer to an article, not the article — and sending the whole body would
  # both flood timelines and hand every instance a full copy to cache.
  defp content_html(document) do
    title = escape(document.title || document.url)
    summary = document[:summary]

    body =
      if is_binary(summary) and summary != "" do
        "<p>#{escape(summary)}</p>"
      else
        ""
      end

    ~s(<p><a href="#{escape(document.url)}">#{title}</a></p>) <> body
  end

  defp put_source(map, markdown) when is_binary(markdown) and markdown != "" do
    Map.put(map, "source", %{"content" => markdown, "mediaType" => "text/markdown"})
  end

  defp put_source(map, _markdown), do: map

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_other), do: nil

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
