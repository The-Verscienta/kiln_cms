defmodule KilnCMS.Social.Providers.Bluesky do
  @moduledoc """
  Posts to Bluesky over the AT Protocol XRPC API (#497).

  Two calls: `com.atproto.server.createSession` exchanges the handle and an
  **app password** for an access JWT, then `com.atproto.repo.createRecord`
  writes an `app.bsky.feed.post` into the account's repo.

  Credential: an app password (Settings → Privacy and security → App
  Passwords), never the account password. An app password can be revoked
  individually and cannot change the account's own password, which is the whole
  reason to use one for a machine client.

  ## Facets, and why the offsets are in BYTES

  A Bluesky post is plain text; a link is only clickable if the post carries a
  *facet* naming the byte range the link occupies. The protocol is explicit that
  the range is measured in **UTF-8 bytes**, not characters — the field is
  literally `byteStart`/`byteEnd`.

  This is the bug worth writing down, because it is invisible in testing: with
  an ASCII-only title the two agree, so a character-offset implementation
  passes every test anyone writes by hand. The first post whose title contains
  an em dash, an accent or an emoji silently shifts the range, and the link
  either highlights the wrong span or vanishes. So the offset comes from
  `byte_size/1` on the prefix, and there is a test with a multibyte title
  specifically to keep it that way.

  ## No server-side idempotency

  Unlike Mastodon, `createRecord` has no idempotency key. A repeat creates a
  second post. That is the reason the ledger claims *before* it posts and never
  auto-retries an `:unknown`.
  """
  @behaviour KilnCMS.Social.Provider

  alias KilnCMS.Social.Account

  # Bluesky's graphemes limit for `app.bsky.feed.post`.
  @max_length 300

  # The public API host. Every account on `bsky.social` uses it; a self-hosted
  # PDS would need its own, which is a v2 concern (and would go through the same
  # SafeFetch call this one does).
  @service "https://bsky.social"

  @impl true
  def max_length, do: @max_length

  @impl true
  def post(account, %{text: text, url: url}) do
    with {:ok, session} <- create_session(account) do
      body =
        Jason.encode!(%{
          repo: session["did"],
          collection: "app.bsky.feed.post",
          record: %{
            "$type" => "app.bsky.feed.post",
            "text" => text,
            "createdAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "facets" => link_facets(text, url)
          }
        })

      @service
      |> xrpc("com.atproto.repo.createRecord")
      |> KilnCMS.SafeFetch.post(body,
        headers: [
          {"authorization", "Bearer " <> session["accessJwt"]},
          {"content-type", "application/json"}
        ],
        receive_timeout: 15_000,
        req_options: KilnCMS.Social.req_options()
      )
      |> handle_create(account)
    end
  end

  @impl true
  def verify(account) do
    # `create_session/1` never answers `:unknown`: a session call creates no
    # record, so even an ambiguous transport failure is a definite non-post.
    case create_session(account) do
      {:ok, _session} -> :ok
      {:error, {:failed, reason}} -> {:error, reason}
    end
  end

  @doc """
  The facets for every occurrence of `url` in `text`, with **byte** offsets.

  Public because the byte-offset rule is the part of this module most likely to
  be got wrong by a future edit, and a test that has to reach through `post/2`
  to check it would not be read as being about offsets.
  """
  @spec link_facets(String.t(), String.t()) :: [map()]
  def link_facets(text, url) when is_binary(text) and is_binary(url) and url != "" do
    case :binary.match(text, url) do
      :nomatch ->
        []

      {start, length} ->
        [
          %{
            "index" => %{"byteStart" => start, "byteEnd" => start + length},
            "features" => [%{"$type" => "app.bsky.richtext.facet#link", "uri" => url}]
          }
        ]
    end
  end

  def link_facets(_text, _url), do: []

  defp create_session(account) do
    with {:ok, password} <- credential(account),
         {:ok, handle} <- handle(account) do
      body = Jason.encode!(%{identifier: handle, password: password})

      @service
      |> xrpc("com.atproto.server.createSession")
      |> KilnCMS.SafeFetch.post(body,
        headers: [{"content-type", "application/json"}],
        req_options: KilnCMS.Social.req_options()
      )
      |> handle_session()
    end
  end

  defp handle_session({:ok, %{status: 200, body: body}}) do
    case Jason.decode(body) do
      {:ok, %{"accessJwt" => _, "did" => _} = session} -> {:ok, session}
      _ -> {:error, {:failed, "Bluesky returned a session we could not read"}}
    end
  end

  # Sign-in refused: wrong handle, wrong or revoked app password. Definite, and
  # nothing was posted — a session call creates no record.
  defp handle_session({:ok, %{status: status}}) when status in 400..499,
    do: {:error, {:failed, "Bluesky refused the credentials (#{status})"}}

  defp handle_session({:ok, %{status: status}}),
    do: {:error, {:failed, "Bluesky answered #{status}"}}

  # A failed session means no post was attempted, so this is safe to call a
  # definite failure even though the transport was ambiguous — unlike the
  # create-record call below, where the same ambiguity is unresolvable.
  defp handle_session({:error, reason}), do: {:error, {:failed, reason}}

  defp handle_create({:ok, %{status: 200, body: body}}, account) do
    case Jason.decode(body) do
      {:ok, %{"uri" => uri}} -> {:ok, %{id: uri, url: web_url(uri, account)}}
      _ -> {:error, :unknown}
    end
  end

  defp handle_create({:ok, %{status: status}}, _account) when status in 400..499,
    do: {:error, {:failed, "Bluesky rejected the post (#{status})"}}

  defp handle_create({:ok, %{status: _5xx}}, _account), do: {:error, :unknown}
  defp handle_create({:error, _reason}, _account), do: {:error, :unknown}

  # `at://did:plc:abc/app.bsky.feed.post/3k…` → the bsky.app permalink. Best
  # effort: an unrecognised URI shape yields `nil` rather than a broken link in
  # the ledger.
  defp web_url(uri, %{handle: handle}) when is_binary(handle) do
    case String.split(uri, "/") do
      [_at, _blank, _did, _collection, rkey] -> "https://bsky.app/profile/#{handle}/post/#{rkey}"
      _ -> nil
    end
  end

  defp web_url(_uri, _account), do: nil

  defp xrpc(service, method), do: service <> "/xrpc/" <> method

  defp credential(account) do
    case Account.credential(account) do
      nil -> {:error, {:failed, "no usable app password stored"}}
      password -> {:ok, password}
    end
  end

  defp handle(%{handle: handle}) when is_binary(handle) and handle != "", do: {:ok, handle}
  defp handle(_account), do: {:error, {:failed, "no handle configured"}}
end
