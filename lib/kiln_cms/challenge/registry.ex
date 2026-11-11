defmodule KilnCMS.Challenge.Registry do
  @moduledoc """
  The human-verification providers an operator may name (#2249): the
  built-ins, then every installed plugin's `c:Kiln.Plugin.challenge_providers/0`,
  then `providers:` from `KilnCMS.Challenge`'s config (a test seam, not a
  plugin path).

  A provider is chosen by its id (`CHALLENGE_PROVIDER`), and the first module
  answering to it wins, so a plugin can never take over `turnstile` or
  `recaptcha`. A plugin compiled against a `kiln_plugin` older than 1.4 has no
  such callback and contributes none, and a module whose callbacks raise is
  skipped rather than taking the caller down: every read here is on a request
  path's behalf, even though `KilnCMS.Challenge` memoises what it resolves.
  """

  alias KilnCMS.Challenge.Providers.Recaptcha
  alias KilnCMS.Challenge.Providers.Turnstile

  @built_in [Turnstile, Recaptcha]

  @response_fields_key {__MODULE__, :response_fields}

  @doc "The built-in providers, Turnstile first (the recommended one)."
  @spec built_in() :: [module()]
  def built_in, do: @built_in

  @doc "Every provider module, built-ins first, each once."
  @spec providers() :: [module()]
  def providers do
    Enum.uniq(@built_in ++ plugin_providers() ++ configured())
  end

  @doc "Providers contributed by installed plugins."
  @spec plugin_providers() :: [module()]
  def plugin_providers, do: Enum.flat_map(Kiln.Plugins.all(), &of_plugin/1)

  @doc """
  What `plugin` contributes. Tolerant: no callback (an older SDK), a raising
  one, or something that is not a list of modules contributes nothing.
  """
  @spec of_plugin(module()) :: [module()]
  def of_plugin(plugin) do
    with true <- Code.ensure_loaded?(plugin),
         true <- function_exported?(plugin, :challenge_providers, 0),
         list when is_list(list) <- safely(fn -> plugin.challenge_providers() end) do
      Enum.filter(list, &is_atom/1)
    else
      _none -> []
    end
  end

  defp configured do
    case Keyword.get(Application.get_env(:kiln_cms, KilnCMS.Challenge, []), :providers, []) do
      list when is_list(list) -> Enum.filter(list, &is_atom/1)
      _other -> []
    end
  end

  @doc "The first provider module answering to `id`, or `:error`."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id) when is_binary(id) do
    case Enum.find(providers(), &(id_of(&1) == id)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  def fetch(_id), do: :error

  @doc "The ids an operator can name, in registration order, for messages."
  @spec ids() :: [String.t()]
  def ids do
    providers() |> Enum.map(&id_of/1) |> Enum.filter(&is_binary/1) |> Enum.uniq()
  end

  @doc """
  `module`'s id, or `nil` when it is not a provider or `id/0` raises or
  answers anything but a string.
  """
  @spec id_of(module()) :: String.t() | nil
  def id_of(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :id, 0),
         id when is_binary(id) <- safely(fn -> module.id() end) do
      id
    else
      _not_a_provider -> nil
    end
  end

  @doc """
  The form fields every registered provider's own markup may post its token
  under (`response_field`), for the request log's and Sentry's filters.
  Computed once per node: the providers are fixed per build, apart from the
  test seam.
  """
  @spec response_fields() :: [String.t()]
  def response_fields do
    case :persistent_term.get(@response_fields_key, nil) do
      fields when is_list(fields) ->
        fields

      nil ->
        fields = compute_response_fields()
        :persistent_term.put(@response_fields_key, fields)
        fields
    end
  end

  defp compute_response_fields do
    providers()
    |> Enum.flat_map(fn module ->
      case safely(fn -> module.widget() end) do
        %{response_field: field} when is_binary(field) and field != "" -> [field]
        _none -> []
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  `fields` merged into Phoenix's `:filter_parameters` value `current`.
  Which fields `current` already filters is asked of Phoenix itself
  (`Phoenix.Logger`'s own `filter_values`), so it works for every shape:

    * `:unchanged` — it filters all of them;
    * `{:ok, list}` — `current` is a plain list, with the missing ones added;
    * `{:unfiltered, missing}` — `current` is any other shape (`{:keep, _}`,
      or the form Phoenix compiles a list into when it starts) and misses
      some. It is the operator's, so it is never rewritten.
  """
  @spec merge_filter_parameters(term(), [String.t()]) ::
          {:ok, [String.t()]} | :unchanged | {:unfiltered, [String.t()]}
  def merge_filter_parameters(current, fields) do
    case Enum.reject(fields, &filtered?(current, &1)) do
      [] -> :unchanged
      missing when is_list(current) -> {:ok, current ++ missing}
      missing -> {:unfiltered, missing}
    end
  end

  defp filtered?(current, field) do
    Phoenix.Logger.filter_values(%{field => "x"}, current) == %{field => "[FILTERED]"}
  rescue
    _unreadable -> false
  end

  @doc false
  # Test seam: forget the memoised response fields.
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@response_fields_key)
    :ok
  end

  defp safely(fun) do
    fun.()
  rescue
    _error -> :raised
  catch
    _kind, _reason -> :raised
  end
end
