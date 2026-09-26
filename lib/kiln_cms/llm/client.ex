defmodule KilnCMS.LLM.Client do
  @moduledoc """
  The one place the shipped generators call a model, for a
  `KilnCMS.LLM.Route` (#1557).

  Three paths:

    * **The operator's route** — `req_llm`, exactly as before #1557: the
      operator's model spec, and whatever key and endpoint `req_llm` finds in
      the operator's config and environment.
    * **A site's hosted provider** — `req_llm` with the site's key and the
      provider's published API root passed **explicitly**, after every
      credential- or endpoint-shaped option is stripped. `req_llm` falls back to
      the operator's `config :req_llm` and `<PROVIDER>_API_KEY` for anything
      not passed, so "not passed" is the bug this module exists to rule out.
      See `KilnCMS.LLM.SiteProvider`.
    * **A site's OpenAI-compatible endpoint** — the host is tenant-chosen, so
      the request goes through `KilnCMS.SafeFetch` (SSRF check, pinned address,
      no redirects, a response-size cap) rather than through `req_llm`'s own
      Req client, which would resolve the name itself and follow redirects past
      the check. Plain chat completions only; structured output is reported
      unsupported so `KilnCMS.Seo` uses its free-text tier.

  Every path returns `{:ok, text_or_object, usage}` or `{:error, reason}`.
  `usage` is a map with `:input_tokens` / `:output_tokens` when the provider
  reported them, `%{}` otherwise.
  """

  alias KilnCMS.CMS.Validations.AiBaseUrl
  alias KilnCMS.LLM.Route
  alias KilnCMS.SafeFetch

  # Options through which a request could pick up a credential or an endpoint.
  # Dropped from a site request before the site's own are put back, so nothing
  # a caller (or the operator's feature config) put in `opts` can override them.
  @credential_opts [
    :api_key,
    :base_url,
    :access_token,
    :auth_mode,
    :provider_options,
    :req_http_options
  ]

  # A chat completion is a few KB. The cap is for an endpoint that isn't one.
  @max_response_bytes 1_000_000

  @doc "Generate text for `user` under `opts` (`:system_prompt`, `:temperature`, …)."
  @spec text(Route.t(), String.t(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def text(%Route{source: :site, provider: :openai_compatible} = route, user, opts),
    do: compatible(route, user, opts)

  def text(%Route{} = route, user, opts) do
    with {:ok, response} <- ReqLLM.generate_text(route.model, user, request_opts(route, opts)),
         text when is_binary(text) <- ReqLLM.Response.text(response) do
      {:ok, text, usage(response)}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unparsable}
    end
  end

  @doc """
  Generate an object matching `schema` — the provider's structured-output
  path. `{:error, :unsupported}` for an OpenAI-compatible endpoint.
  """
  @spec object(Route.t(), String.t(), keyword(), keyword()) ::
          {:ok, map(), map()} | {:error, term()}
  def object(%Route{source: :site, provider: :openai_compatible}, _user, _schema, _opts),
    do: {:error, :unsupported}

  def object(%Route{} = route, user, schema, opts) do
    with {:ok, response} <-
           ReqLLM.generate_object(route.model, user, schema, request_opts(route, opts)),
         object when is_map(object) <- ReqLLM.Response.object(response) do
      {:ok, object, usage(response)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unusable_object, other}}
    end
  end

  @doc false
  # The options a request is sent with. Public so the isolation test can pin
  # the value as well as the request.
  @spec request_opts(Route.t(), keyword()) :: keyword()
  def request_opts(%Route{source: :operator}, opts), do: opts

  def request_opts(%Route{source: :site} = route, opts) do
    opts
    |> Keyword.drop(@credential_opts)
    # Never `nil`: `req_llm` treats a nil `:api_key` as "look elsewhere", and
    # elsewhere is the operator's. An empty one is refused outright.
    |> Keyword.put(:api_key, route.api_key || "")
    |> Keyword.put(:base_url, route.base_url)
    |> Keyword.merge(test_http_options())
  end

  defp usage(response) do
    case ReqLLM.Response.usage(response) do
      %{} = usage -> usage
      _ -> %{}
    end
  end

  # ── OpenAI-compatible, over SafeFetch ────────────────────────────────────

  defp compatible(route, user, opts) do
    with :ok <- https_only(route.base_url) do
      url = String.trim_trailing(route.base_url, "/") <> "/chat/completions"

      body =
        %{model: route.model, messages: messages(opts[:system_prompt], user)}
        |> put_present(:temperature, opts[:temperature])
        |> put_present(:max_tokens, opts[:max_tokens])

      url
      |> SafeFetch.post(Jason.encode!(body),
        headers:
          [{"content-type", "application/json"}, {"accept", "application/json"}] ++
            authorization(route.api_key),
        receive_timeout: Keyword.get(opts, :receive_timeout, 30_000),
        max_bytes: @max_response_bytes,
        req_options: Keyword.get(config(), :req_options, [])
      )
      |> completion()
    end
  end

  # SafeFetch allows plain HTTP unless the operator turned `require_https` on;
  # this request carries a key, so it is https or nothing. Re-checked here as
  # well as at save, for a row written before the rule.
  defp https_only(url) when is_binary(url) do
    case AiBaseUrl.check(url) do
      :ok -> :ok
      {:error, error} -> {:error, "blocked URL: " <> error.message}
    end
  end

  defp https_only(_url), do: {:error, "blocked URL: no endpoint is set"}

  defp messages(system, user) when is_binary(system) and system != "",
    do: [%{role: "system", content: system}, %{role: "user", content: user}]

  defp messages(_system, user), do: [%{role: "user", content: user}]

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp authorization(key) when is_binary(key) and key != "",
    do: [{"authorization", "Bearer " <> key}]

  defp authorization(_key), do: []

  # The error names the status, never the body: the body is the far end's to
  # write, and it is shown to the editor.
  defp completion({:ok, %{status: status, body: body}}) when status in 200..299 do
    with {:ok, decoded} <- Jason.decode(body),
         %{"choices" => [%{"message" => %{"content" => text}} | _rest]} when is_binary(text) <-
           decoded do
      {:ok, text, compatible_usage(decoded["usage"])}
    else
      _unusable -> {:error, :unparsable}
    end
  end

  defp completion({:ok, %{status: status}}), do: {:error, "the endpoint answered #{status}"}
  defp completion({:error, message}), do: {:error, message}

  defp compatible_usage(%{} = usage) do
    %{input_tokens: usage["prompt_tokens"], output_tokens: usage["completion_tokens"]}
    |> Map.reject(fn {_key, value} -> not is_integer(value) end)
  end

  defp compatible_usage(_usage), do: %{}

  # `req_http_options` for a site's hosted-provider request — a test seam, so
  # the isolation test can see the request `req_llm` actually builds
  # (`plug: {Req.Test, …}`). Operator config; a tenant cannot reach it.
  defp test_http_options do
    case Keyword.get(config(), :req_http_options) do
      nil -> []
      options -> [req_http_options: options]
    end
  end

  defp config, do: Application.get_env(:kiln_cms, KilnCMS.LLM.SiteProvider, [])
end
