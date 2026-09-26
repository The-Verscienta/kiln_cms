defmodule KilnCMS.Seo.Generator.ReqLLM do
  @moduledoc """
  The shipped `KilnCMS.Seo.Generator`, built on `req_llm`.

  Provider-agnostic by construction: the model spec is a plain
  `"provider:model"` string, `req_llm` carries `ollama` and `vllm` providers
  alongside the hosted ones, and any provider's `base_url` can be overridden.
  Pointing it at a local endpoint keeps content inside the deployment, which is
  why shipping this module is not the same as shipping egress. It is inert
  until an operator sets both `generator:` and `model:`.

  ## Two parsing tiers, and why the second is not optional

  1. `ReqLLM.generate_object/4` with `KilnCMS.Seo.Draft.schema/0` — the
     provider's native structured-output path, validated and coerced by
     `req_llm` before we see it.
  2. `ReqLLM.generate_text/3` plus `Draft.parse_text/1`.

  Tier 2 exists because tier 1 needs provider-side tool-calling or JSON-schema
  support, and the small local models we *recommend* running are exactly the
  ones most likely to lack it. Treating it as a defensive afterthought would
  mean the on-prem configuration silently never works.

  Either way the result goes through `Draft.normalize/1` — this module never
  returns text a caller could trust as-is.
  """

  @behaviour KilnCMS.Seo.Generator

  require Logger

  alias KilnCMS.LLM.Client
  alias KilnCMS.Seo.Draft
  alias KilnCMS.Seo.Prompt

  @impl KilnCMS.Seo.Generator
  def draft(document, opts \\ []) do
    # `:llm` is a site's own route (#1557), put there by `KilnCMS.Seo.draft/2`;
    # without one this is the operator's configuration, as it always was.
    route = Keyword.get(opts, :llm) || KilnCMS.Seo.operator_route()
    {system, user} = Prompt.build(document, Keyword.delete(opts, :llm))

    request =
      route
      |> KilnCMS.Seo.request_opts()
      |> Keyword.merge(Keyword.take(opts, [:temperature, :max_tokens, :receive_timeout]))
      |> Keyword.put(:system_prompt, system)

    case structured(route, user, request) do
      {:ok, draft} ->
        {:ok, draft}

      {:error, reason} ->
        Logger.debug("SEO structured drafting failed (#{inspect(reason)}); trying free text")
        freeform(route, user, request)
    end
  end

  # Tier 1 — provider-native structured output.
  defp structured(route, user, request) do
    with {:ok, object, usage} <- Client.object(route, user, Draft.schema(), request),
         {:ok, draft} <- Draft.from_map(object) do
      {:ok, %{draft | model: route.model, usage: present_usage(usage)}}
    end
  end

  # Tier 2 — ask for JSON in plain text and recover the object ourselves.
  defp freeform(route, user, request) do
    request =
      Keyword.update!(
        request,
        :system_prompt,
        &(&1 <> "\n\nRespond with a single JSON object and nothing else.")
      )

    with {:ok, text, usage} <- Client.text(route, user, request),
         {:ok, object} <- Draft.parse_text(text),
         {:ok, draft} <- Draft.from_map(object) do
      {:ok, %{draft | model: route.model, usage: present_usage(usage)}}
    else
      {:error, %{__exception__: true} = exception} -> {:error, Exception.message(exception)}
      {:error, reason} -> {:error, reason}
    end
  end

  # A draft's `usage` stays `nil` when the provider reported none, as before.
  defp present_usage(usage) when map_size(usage) == 0, do: nil
  defp present_usage(usage), do: usage
end
