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

  @impl KilnCMS.Assist.Generator
  def generate(request, opts \\ []) do
    {system, user} = Prompt.build(request)
    model = Assist.model()

    req_opts =
      Assist.request_opts()
      |> Keyword.merge(Keyword.take(opts, [:temperature, :max_tokens, :receive_timeout]))
      |> Keyword.put(:system_prompt, system)

    with {:ok, response} <- ReqLLM.generate_text(model, user, req_opts),
         text when is_binary(text) <- ReqLLM.Response.text(response) do
      {:ok, text, usage(response)}
    else
      {:error, %{__exception__: true} = exception} -> {:error, Exception.message(exception)}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unparsable}
    end
  end

  defp usage(response) do
    case ReqLLM.Response.usage(response) do
      %{} = usage -> usage
      _ -> %{}
    end
  end
end
