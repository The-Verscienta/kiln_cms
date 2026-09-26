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
  comes back as `{:error, _}`, which `KilnCMS.Ask` degrades to retrieval-only;
  it never 500s the ask. The response takes the same shape a default install's
  does, but says so: `generation: :failed` rather than `:disabled` (#853), so a
  broken endpoint is not mistaken for a feature nobody turned on.
  """

  @behaviour KilnCMS.Ask.Generator

  alias KilnCMS.Ask
  alias KilnCMS.Ask.Prompt
  alias KilnCMS.LLM.Client
  alias KilnCMS.LLM.Route

  @impl KilnCMS.Ask.Generator
  def generate(question, sources), do: generate(question, sources, [])

  @impl KilnCMS.Ask.Generator
  def generate(question, sources, opts) do
    # `:llm` is a site's own route (#1557), put there by `KilnCMS.Ask`;
    # without one this is the operator's configuration, as it always was.
    route = Keyword.get(opts, :llm) || Route.operator(Ask.model())

    case route.model do
      nil ->
        # Configured as the generator with no model spec: nothing to call.
        # `KilnCMS.Ask.enabled?/0` already reports this combination as off, so
        # this is the belt to that braces — reachable only via an explicit
        # `generator:` override in a test or a direct call.
        {:error, :no_model}

      _model ->
        {system, user} = Prompt.build(question, sources, Keyword.delete(opts, :llm))
        request = Keyword.put(Ask.request_opts(route), :system_prompt, system)
        run(route, user, request)
    end
  end

  defp run(route, user, request) do
    case Client.text(route, user, request) do
      {:ok, text, _usage} -> {:ok, text}
      {:error, %{__exception__: true} = exception} -> {:error, Exception.message(exception)}
      {:error, reason} -> {:error, reason}
    end
  end
end
