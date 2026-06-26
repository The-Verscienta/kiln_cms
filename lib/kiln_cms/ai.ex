defmodule KilnCMS.AI do
  @moduledoc """
  AI content-generation assistant (issue #60).

  A thin facade over a pluggable LLM provider (`KilnCMS.AI.Provider`) offering
  block-level authoring helpers — generate, summarize, and SEO suggestions. The
  provider is configured, so the editor never hardcodes a vendor:

      config :kiln_cms, KilnCMS.AI, adapter: KilnCMS.AI.Anthropic

  The default adapter is `KilnCMS.AI.Echo` (offline, no API key), so the feature
  is always callable; production wires `KilnCMS.AI.Anthropic` (Claude) when an
  API key is present (see `config/runtime.exs`).
  """
  @default_adapter KilnCMS.AI.Echo

  @doc "The configured provider module."
  @spec adapter() :: module()
  def adapter do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:adapter, @default_adapter)
  end

  @doc """
  Whether AI assist is enabled. True unless explicitly disabled in config; the
  default Echo adapter keeps it on even without an API key.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :kiln_cms
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @doc "Free-form generation from a prompt."
  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(prompt, opts \\ []), do: adapter().complete(prompt, opts)

  @doc "Summarize `text` into a short paragraph."
  @spec summarize(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def summarize(text, opts \\ []) do
    adapter().complete(
      "Summarize the following content in 2-3 sentences for an editor:\n\n#{text}",
      Keyword.merge(
        [system: "You are a concise editorial assistant.", max_tokens: 300, max_chars: 400],
        opts
      )
    )
  end

  @doc """
  Suggest an SEO meta description (<= ~160 chars) from `text`.
  """
  @spec seo_description(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def seo_description(text, opts \\ []) do
    adapter().complete(
      "Write a compelling SEO meta description (max 160 characters, no quotes) " <>
        "for this content:\n\n#{text}",
      Keyword.merge(
        [
          system: "You write concise, search-optimized meta descriptions.",
          max_tokens: 200,
          max_chars: 160
        ],
        opts
      )
    )
    |> trim_to(160)
  end

  @doc "Suggest an SEO title (<= ~60 chars) from `text`."
  @spec seo_title(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def seo_title(text, opts \\ []) do
    adapter().complete(
      "Write a concise SEO title (max 60 characters, no quotes) for this content:\n\n#{text}",
      Keyword.merge(
        [
          system: "You write concise, search-optimized titles.",
          max_tokens: 80,
          max_chars: 60
        ],
        opts
      )
    )
    |> trim_to(60)
  end

  defp trim_to({:ok, text}, limit), do: {:ok, text |> String.trim() |> String.slice(0, limit)}
  defp trim_to(other, _limit), do: other
end
