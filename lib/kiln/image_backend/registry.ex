defmodule Kiln.ImageBackend.Registry do
  @moduledoc """
  Finds image backends (`Kiln.ImageBackend`, #1955): the one new uploads go
  to, and the one a stored item names.

  Backends come from plugins (`c:Kiln.Plugin.image_backends/0`); the operator
  picks one of them for new uploads:

      config :kiln_cms, :image_backend, MyPlugin.ImageBackend

  The two questions have different answers on purpose. `active/0` is about
  the *next* upload and follows the config. `fetch/1` is about a file that
  already exists and follows the row: an item stays with the backend that
  holds it when the operator switches to another one, or turns the setting
  off — as long as that backend is still installed.
  """

  require Logger

  @doc """
  Every installed backend: the plugin-contributed ones, plus the configured
  one if no plugin declares it (a deployment wiring a backend straight into
  config; `mix kiln.plugins.doctor` flags that).
  """
  @spec installed() :: [module()]
  def installed do
    case configured() do
      nil -> Kiln.Plugins.image_backends()
      module -> Enum.uniq(Kiln.Plugins.image_backends() ++ [module])
    end
  end

  @doc "The backend set in `config :kiln_cms, :image_backend`, or `nil`."
  @spec configured() :: module() | nil
  def configured do
    case Application.get_env(:kiln_cms, :image_backend) do
      module when is_atom(module) and not is_nil(module) -> module
      _unset -> nil
    end
  end

  @doc """
  The backend new image uploads are offered to: the configured one, when it
  is a loaded `Kiln.ImageBackend` that reports itself `configured?/0`.
  Anything less is `nil` — uploads then go to the operator's store, which is
  where they went before backends existed.
  """
  @spec active() :: module() | nil
  def active do
    with module when not is_nil(module) <- configured(),
         true <- backend?(module),
         true <- safely(module, :configured?, [], false) do
      module
    else
      _ -> nil
    end
  end

  @doc """
  The active backend, if it takes `candidate` (`t:Kiln.ImageBackend.candidate/0`).
  A backend that raises deciding is treated as declining — an upload must not
  fail because a plugin's predicate did.
  """
  @spec accepting(Kiln.ImageBackend.candidate()) :: module() | nil
  def accepting(candidate) do
    with module when not is_nil(module) <- active(),
         true <- safely(module, :accepts?, [candidate], false) do
      module
    else
      _ -> nil
    end
  end

  @doc """
  The installed backend whose `name/0` is `name`. `{:error, :not_installed}`
  when none is: the plugin holding that item's file was removed, and the
  file cannot be reached until it is put back.
  """
  @spec fetch(String.t()) :: {:ok, module()} | {:error, :not_installed}
  def fetch(name) when is_binary(name) do
    case Enum.find(installed(), &(backend?(&1) and safely(&1, :name, [], nil) == name)) do
      nil -> {:error, :not_installed}
      module -> {:ok, module}
    end
  end

  @doc """
  The selected backend's image origins, for the browser CSP's `img-src`.

  The *selected* one — whether or not it is `configured?/0` right now, since
  a lapsed credential doesn't move the images it already holds — and not
  every installed one: installing a plugin is not a reason to widen the
  policy. An operator who moves to another backend while the old one still
  holds images keeps its origin in `CSP_IMG_SRC`.
  """
  @spec csp_hosts() :: [String.t()]
  def csp_hosts do
    with module when not is_nil(module) <- configured(),
         true <- backend?(module),
         hosts when is_list(hosts) <- safely(module, :csp_hosts, [], []) do
      hosts |> Enum.filter(&is_binary/1) |> Enum.uniq()
    else
      _ -> []
    end
  end

  @doc """
  Asks `backend` whether its service answers (`c:Kiln.ImageBackend.check/0`),
  for System → Image backend.

  Never raises, whatever the plugin does: a raise, an exit or an answer of
  the wrong shape is `{:error, message}`, and a backend written without
  `use Kiln.ImageBackend` — so with no `check/0` — is `:unsupported`. Facts
  that aren't string pairs are dropped rather than rendered.
  """
  @spec check(module()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, String.t()} | :unsupported
  def check(backend) do
    if Code.ensure_loaded?(backend) and function_exported?(backend, :check, 0) do
      backend.check() |> normalize_check(backend)
    else
      :unsupported
    end
  rescue
    error -> check_failed(backend, Exception.message(error))
  catch
    kind, reason -> check_failed(backend, Exception.format_banner(kind, reason))
  end

  defp normalize_check({:ok, facts}, _backend) when is_list(facts),
    do:
      {:ok,
       for({label, value} when is_binary(label) and is_binary(value) <- facts, do: {label, value})}

  defp normalize_check({:error, reason}, _backend) when is_binary(reason), do: {:error, reason}
  defp normalize_check({:error, reason}, _backend), do: {:error, inspect(reason)}
  defp normalize_check(:unsupported, _backend), do: :unsupported

  defp normalize_check(other, backend),
    do: check_failed(backend, "unexpected answer: #{inspect(other, limit: 5)}")

  defp check_failed(backend, message) do
    Logger.error("Image backend #{inspect(backend)}.check/0 failed: #{message}")
    {:error, message}
  end

  @doc "The installed plugin that contributes `backend`, or `nil` (one wired straight into config)."
  @spec plugin_for(module()) :: module() | nil
  def plugin_for(backend) do
    Enum.find(Kiln.Plugins.all(), &(backend in &1.image_backends()))
  end

  @doc "Whether `module` is loaded and implements `Kiln.ImageBackend`."
  @spec backend?(module()) :: boolean()
  def backend?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and Kiln.ImageBackend in behaviours(module)
  end

  def backend?(_other), do: false

  defp behaviours(module) do
    :attributes |> module.module_info() |> Keyword.get_values(:behaviour) |> List.flatten()
  end

  defp safely(module, fun, args, fallback) do
    apply(module, fun, args)
  rescue
    error ->
      Logger.error(
        "Image backend #{inspect(module)}.#{fun}/#{length(args)} raised: " <>
          Exception.message(error)
      )

      fallback
  end
end
