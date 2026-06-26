defmodule KilnCMS.AI.Provider do
  @moduledoc """
  Behaviour for pluggable LLM providers behind the AI content assistant
  (issue #60). A provider turns a text prompt into a completion.

  Select the active provider in config:

      config :kiln_cms, KilnCMS.AI, adapter: KilnCMS.AI.Anthropic

  Ships with `KilnCMS.AI.Echo` (default — deterministic, offline, no API key)
  and `KilnCMS.AI.Anthropic` (Claude via the Messages API). Implement this
  behaviour to add another provider.
  """

  @doc """
  Complete `prompt`, returning `{:ok, text}` or `{:error, reason}`.

  Options:
    * `:system` — system prompt steering the response.
    * `:max_tokens` — output cap (provider default otherwise).
  """
  @callback complete(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
