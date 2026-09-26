defmodule KilnCMS.Assist.Generator.ReqLLM do
  @moduledoc """
  The shipped `KilnCMS.Assist.Generator`, built on `req_llm`.

  Provider-agnostic by construction: the model spec is a plain
  `"provider:model"` string, `req_llm` carries `ollama` and `vllm` providers
  alongside the hosted ones, and any provider's `base_url` can be overridden.
  Pointing it at a local endpoint keeps content inside the deployment, which is
  why shipping this module is not the same as shipping egress. It is inert
  until an operator sets both `generator:` and `model:`.

  One parsing tier, unlike `KilnCMS.Seo.Generator.ReqLLM`'s two: the output is
  prose, so there is no object to coerce and nothing for a provider without
  tool-calling to fail at. `generate_text/3` is the whole path.
  """

  @behaviour KilnCMS.Assist.Generator

  alias KilnCMS.Assist
  alias KilnCMS.Assist.Prompt
  alias KilnCMS.LLM.Client

  @impl KilnCMS.Assist.Generator
  def generate(request, opts \\ []) do
    {system, user} = Prompt.build(request)
    # `:llm` is a site's own route (#1557), put there by `KilnCMS.Assist.run/2`;
    # without one this is the operator's configuration, as it always was.
    route = Keyword.get(opts, :llm) || Assist.operator_route()

    req_opts =
      route
      |> Assist.request_opts()
      |> Keyword.merge(Keyword.take(opts, [:temperature, :max_tokens, :receive_timeout]))
      |> Keyword.put(:system_prompt, system)

    case Client.text(route, user, req_opts) do
      {:ok, text, usage} -> {:ok, text, usage}
      {:error, %{__exception__: true} = exception} -> {:error, Exception.message(exception)}
      {:error, reason} -> {:error, reason}
    end
  end
end
