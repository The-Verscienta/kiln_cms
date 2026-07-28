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

  alias KilnCMS.Seo.Draft
  alias KilnCMS.Seo.Prompt

  @impl KilnCMS.Seo.Generator
  def draft(document, opts \\ []) do
    {system, user} = Prompt.build(document, opts)
    model = KilnCMS.Seo.model()

    request =
      KilnCMS.Seo.request_opts()
      |> Keyword.merge(Keyword.take(opts, [:temperature, :max_tokens, :receive_timeout]))
      |> Keyword.put(:system_prompt, system)

    case structured(model, user, request) do
      {:ok, draft} ->
        {:ok, draft}

      {:error, reason} ->
        Logger.debug("SEO structured drafting failed (#{inspect(reason)}); trying free text")
        freeform(model, user, request)
    end
  end

  # Tier 1 — provider-native structured output.
  defp structured(model, user, request) do
    with {:ok, response} <- ReqLLM.generate_object(model, user, Draft.schema(), request),
         object when is_map(object) <- ReqLLM.Response.object(response),
         {:ok, draft} <- Draft.from_map(object) do
      {:ok, %{draft | model: model, usage: usage(response)}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unusable_object, other}}
    end
  end

  # Tier 2 — ask for JSON in plain text and recover the object ourselves.
  defp freeform(model, user, request) do
    request =
      Keyword.update!(
        request,
        :system_prompt,
        &(&1 <> "\n\nRespond with a single JSON object and nothing else.")
      )

    with {:ok, response} <- ReqLLM.generate_text(model, user, request),
         text when is_binary(text) <- ReqLLM.Response.text(response),
         {:ok, object} <- Draft.parse_text(text),
         {:ok, draft} <- Draft.from_map(object) do
      {:ok, %{draft | model: model, usage: usage(response)}}
    else
      {:error, %{__exception__: true} = exception} -> {:error, Exception.message(exception)}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unparsable}
    end
  end

  defp usage(response) do
    case ReqLLM.Response.usage(response) do
      %{} = usage -> usage
      _ -> nil
    end
  end
end
