defmodule KilnCMS.Social.Providers.Mastodon do
  @moduledoc """
  Posts to a Mastodon account via `POST /api/v1/statuses` (#497).

  Credential: an access token with the `write:statuses` scope, from the
  instance's Development → Applications page. Plus the `instance_url` it belongs
  to — a token is only meaningful against the instance that issued it.

  ## Idempotency-Key is why Mastodon is the easy one

  The API accepts an `Idempotency-Key` header and will not create a second
  status for a repeat of the same key. Kiln sends the ledger row's id, so if a
  response is lost in flight and something re-runs, the instance recognises the
  key and returns the *original* status instead of posting again.

  That is a real guarantee from the server, not a hope, and it is why an
  `:unknown` outcome here is closer to recoverable than it is on Bluesky. Kiln
  still does not auto-retry — the ledger is deliberately terminal — but an
  operator re-triggering by hand is safe in a way it is not elsewhere.

  ## Every request goes through SafeFetch

  `instance_url` is operator-supplied and stored in a database column, so a
  bare HTTP client here would make the settings form a server-side request
  forgery primitive: `http://169.254.169.254/`, `http://localhost:6379/`, a
  hostname that resolves to a private address after validation passed.
  `KilnCMS.SafeFetch` pins the resolved address and refuses the ones that
  matter. The cost is that a Mastodon instance on a private network cannot be
  posted to, which is the correct default and is documented.
  """
  @behaviour KilnCMS.Social.Provider

  alias KilnCMS.Social.Account

  # Mastodon's default `max_toot_chars`. Instances can raise it and some do, but
  # the API does not advertise it anywhere a client can rely on, so the default
  # is the only safe assumption — being 100 characters short of an instance's
  # real limit costs nothing, and being over it is a 422.
  @max_length 500

  @impl true
  def max_length, do: @max_length

  @impl true
  def post(account, %{text: text, idempotency_key: key}) do
    with {:ok, token} <- credential(account),
         {:ok, url} <- endpoint(account, "/api/v1/statuses") do
      body = Jason.encode!(%{status: text, visibility: "public"})

      url
      |> KilnCMS.SafeFetch.post(body,
        headers: [
          {"authorization", "Bearer " <> token},
          {"content-type", "application/json"},
          # The ledger row's id: a repeat of this request cannot create a second
          # status on the instance.
          {"idempotency-key", key}
        ],
        receive_timeout: 15_000,
        req_options: KilnCMS.Social.req_options()
      )
      |> handle_status()
    end
  end

  @impl true
  def verify(account) do
    with {:ok, token} <- credential(account),
         {:ok, url} <- endpoint(account, "/api/v1/accounts/verify_credentials") do
      get_opts = [
        headers: [{"authorization", "Bearer " <> token}],
        req_options: KilnCMS.Social.req_options()
      ]

      case KilnCMS.SafeFetch.get(url, get_opts) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status}} -> {:error, "instance answered #{status}"}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:failed, reason}} -> {:error, reason}
    end
  end

  defp handle_status({:ok, %{status: status, body: body}}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"id" => id} = status_body} ->
        {:ok, %{id: to_string(id), url: status_body["url"]}}

      # A 2xx we cannot parse means it very likely posted — answering `:failed`
      # here would invite a re-trigger that duplicates it.
      _ ->
        {:error, :unknown}
    end
  end

  # 4xx is the instance refusing: bad token, bad body, rate limited. Nothing was
  # created, so this is safe to report as a definite failure.
  defp handle_status({:ok, %{status: status}}) when status in 400..499,
    do: {:error, {:failed, "instance rejected the post (#{status})"}}

  # 5xx may or may not have created the status before falling over.
  defp handle_status({:ok, %{status: _5xx}}), do: {:error, :unknown}

  # A transport error is ambiguous by nature: the bytes may have arrived.
  defp handle_status({:error, _reason}), do: {:error, :unknown}

  defp credential(account) do
    case Account.credential(account) do
      nil -> {:error, {:failed, "no usable access token stored"}}
      token -> {:ok, token}
    end
  end

  defp endpoint(%{instance_url: base}, path) when is_binary(base) do
    {:ok, String.trim_trailing(base, "/") <> path}
  end

  defp endpoint(_account, _path), do: {:error, {:failed, "no instance URL configured"}}
end
