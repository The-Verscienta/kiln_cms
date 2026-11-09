defmodule KilnCMS.Challenge.Transport do
  @moduledoc """
  The one way a challenge provider reaches its verification endpoint (#2249).

  Through `KilnCMS.SafeFetch` like every other outbound call (`AGENTS.md`),
  although the host is the provider's own rather than one content chose: the
  one fetch path means the address pinning, the byte cap and the no-redirect
  rule apply without a second implementation.

  No redirects, no retries, a 16 KB cap (a verification answer is a few hundred
  bytes) and short timeouts — a sign-in must not wait on a third party. The
  overall deadline that bounds the whole call, DNS included, is enforced one
  level up by `KilnCMS.Challenge.verify/4`, which runs the provider in a task.

  Answers `{:ok, %{status: integer(), body: binary()}}` or
  `{:error, class}`, where `class` is `:timeout`, `:transport`, `:blocked` or
  `:malformed_response`. Nothing here logs the token, the secret or the URL.
  """

  alias KilnCMS.SafeFetch

  @default_connect_timeout 1_000
  @default_receive_timeout 2_000
  @max_bytes 16 * 1024

  @type error_class :: :timeout | :transport | :blocked | :malformed_response

  @doc """
  `POST` `fields` to `url` as `application/x-www-form-urlencoded`.

  `config` is `KilnCMS.Challenge`'s configuration (`:connect_timeout`,
  `:receive_timeout`, `:req_options` — the last a `Req.Test` seam).
  """
  @spec post_form(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, %{status: integer(), body: binary()}} | {:error, error_class()}
  def post_form(url, fields, config \\ []) when is_binary(url) and is_list(fields) do
    url
    |> SafeFetch.post(URI.encode_query(fields),
      headers: [
        {"content-type", "application/x-www-form-urlencoded"},
        {"user-agent", "KilnCMS"}
      ],
      max_redirects: 0,
      max_bytes: @max_bytes,
      connect_timeout: Keyword.get(config, :connect_timeout, @default_connect_timeout),
      receive_timeout: Keyword.get(config, :receive_timeout, @default_receive_timeout),
      req_options: Keyword.get(config, :req_options, [])
    )
    |> case do
      {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, classify(reason)}
    end
  end

  defp classify("blocked" <> _rest), do: :blocked
  defp classify("response exceeded" <> _rest), do: :malformed_response
  defp classify("unexpected response body" <> _rest), do: :malformed_response

  defp classify(reason) do
    if String.contains?(String.downcase(reason), "timeout"), do: :timeout, else: :transport
  end
end
