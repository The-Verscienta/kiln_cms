defmodule KilnCMS.AI.Anthropic do
  @moduledoc """
  Claude `KilnCMS.AI.Provider`, talking to the Anthropic Messages API over HTTP
  (via Req — there is no Elixir Anthropic SDK). Configure:

      config :kiln_cms, KilnCMS.AI.Anthropic,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        model: "claude-opus-4-8"

  and select it with `config :kiln_cms, KilnCMS.AI, adapter: KilnCMS.AI.Anthropic`
  (see `config/runtime.exs`, which wires this when ANTHROPIC_API_KEY is set).
  """
  @behaviour KilnCMS.AI.Provider

  @endpoint "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @default_model "claude-opus-4-8"
  @default_max_tokens 1024

  @impl true
  def complete(prompt, opts \\ []) when is_binary(prompt) do
    with {:ok, api_key} <- api_key() do
      body =
        %{
          model: model(),
          max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
          messages: [%{role: "user", content: prompt}]
        }
        |> maybe_put(:system, opts[:system])

      request(api_key, body)
    end
  end

  defp request(api_key, body) do
    case Req.post(@endpoint,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", @api_version}
           ],
           json: body,
           receive_timeout: 60_000,
           retry: :transient
         ) do
      {:ok, %{status: 200, body: resp}} -> extract_text(resp)
      {:ok, %{status: status, body: resp}} -> {:error, {:http_error, status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The Messages API returns content as a list of typed blocks; concatenate the
  # text blocks.
  defp extract_text(%{"content" => blocks}) when is_list(blocks) do
    text =
      blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", & &1["text"])
      |> String.trim()

    if text == "", do: {:error, :empty_completion}, else: {:ok, text}
  end

  defp extract_text(other), do: {:error, {:unexpected_response, other}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])

  defp model, do: config()[:model] || @default_model

  defp api_key do
    case config()[:api_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end
end
