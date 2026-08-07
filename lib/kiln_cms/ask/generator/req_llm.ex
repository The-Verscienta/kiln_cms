defmodule KilnCMS.Ask.Generator.ReqLLM do
  @moduledoc """
  The shipped `KilnCMS.Ask.Generator`, built on `req_llm` (#339 phase 2).

  Provider-agnostic by construction: the model spec is a plain
  `"provider:model"` string, `req_llm` carries `ollama` and `vllm` providers
  alongside the hosted ones, and any provider's `base_url` can be overridden.
  Pointing it at a local endpoint keeps content inside the deployment, which is
  why shipping this module is not the same as shipping egress. It is inert
  until an operator sets both `generator:` and `model:`.

  One parsing tier, like `KilnCMS.Assist.Generator.ReqLLM` and unlike
  `KilnCMS.Seo.Generator.ReqLLM`'s two: the output is prose, so there is no
  object to coerce and nothing for a provider without tool-calling to fail at.

  Every failure — an unset model, a refused request, an unparsable response —
  comes back as `{:error, _}`, which `KilnCMS.Ask` degrades to retrieval-only.
  A misconfigured or unreachable model makes `/api/ask` behave exactly as it
  does on a default install; it never 500s the ask.
  """

  @behaviour KilnCMS.Ask.Generator

  alias KilnCMS.Ask
  alias KilnCMS.Ask.Prompt

  @impl KilnCMS.Ask.Generator
  def generate(question, sources), do: generate(question, sources, [])

  @impl KilnCMS.Ask.Generator
  def generate(question, sources, opts) do
    case Ask.model() do
      nil ->
        # Configured as the generator with no model spec: nothing to call.
        # `KilnCMS.Ask.enabled?/0` already reports this combination as off, so
        # this is the belt to that braces — reachable only via an explicit
        # `generator:` override in a test or a direct call.
        {:error, :no_model}

      model ->
        {system, user} = Prompt.build(question, sources, opts)
        request = Keyword.put(Ask.request_opts(), :system_prompt, system)
        run(model, user, request)
    end
  end

  defp run(model, user, request) do
    with {:ok, response} <- ReqLLM.generate_text(model, user, request),
         text when is_binary(text) <- ReqLLM.Response.text(response) do
      {:ok, text}
    else
      {:error, %{__exception__: true} = exception} -> {:error, Exception.message(exception)}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unparsable}
    end
  end
end
