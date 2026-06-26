defmodule KilnCMS.AI.Echo do
  @moduledoc """
  Default, offline `KilnCMS.AI.Provider` — no API key, no network. It returns a
  deterministic, trimmed echo of the prompt so the AI-assist UI and tests work
  without a real LLM. Swap in `KilnCMS.AI.Anthropic` (or another provider) in
  production for actual generation.
  """
  @behaviour KilnCMS.AI.Provider

  @impl true
  def complete(prompt, opts \\ []) when is_binary(prompt) do
    limit = Keyword.get(opts, :max_chars, 200)

    text =
      prompt
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, limit)

    {:ok, text}
  end
end
