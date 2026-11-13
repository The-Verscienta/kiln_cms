defmodule KilnCMS.Security.Posture.Registry do
  @moduledoc """
  The checks a posture report runs (#2252): the core's own, then every
  installed plugin's `c:Kiln.Plugin.security_checks/0`, then `checks:` from
  `KilnCMS.Security.Posture`'s config (a test seam, not a plugin path).

  Each is resolved with `Kiln.Security.Check.describe/1`. A module that does
  not conform is left out and logged. Ids are unique: a core check always
  wins, a plugin may not take an id under `core.`, and of two plugins
  answering to one id the first registered wins (`mix kiln.plugins.doctor`
  reports the collision). A plugin compiled against a `kiln_plugin` older than
  1.4 has no such callback and contributes none, and a callback that raises
  contributes none rather than taking the page down.

  The metadata (`title/0`, `description/0`) is read on every report, in the
  reader's locale, so a translated title follows the page. Text that is not
  valid UTF-8 has its bad bytes replaced (U+FFFD) rather than the check being
  left out, and a plugin name that is not valid UTF-8 is replaced by the
  plugin's module name, so a report always encodes.
  """

  require Logger

  alias KilnCMS.Security.Posture.Checks

  @core [
    Checks.SecondFactor,
    Checks.IdleTimeout,
    Checks.SecurityAlerts,
    Checks.AdminAllowlist,
    Checks.BreachedPasswords,
    Checks.OperatorSecondFactor,
    Checks.Transport,
    Checks.ExposedEndpoints,
    Checks.ApiKeys,
    Checks.HumanVerification,
    Checks.Release,
    Checks.CoreSecurityNotices,
    Checks.PluginHealth
  ]

  @min_timeout 100
  @max_timeout 5000

  @typedoc "A check as the runner uses it."
  @type descriptor :: %{
          module: module(),
          id: String.t(),
          title: String.t(),
          description: String.t() | nil,
          scope: :site | :deployment,
          timeout: pos_integer(),
          source: :core | {:plugin, String.t()} | :config
        }

  @doc "The core's own check modules."
  @spec core() :: [module()]
  def core, do: @core

  @doc "The check modules installed plugins contribute, in registration order."
  @spec plugin_checks() :: [module()]
  def plugin_checks, do: Enum.flat_map(Kiln.Plugins.all(), &of_plugin/1)

  @doc """
  What `plugin` contributes. Tolerant: no callback (an older SDK), a raising
  one, or something that is not a list of modules contributes nothing.
  """
  @spec of_plugin(module()) :: [module()]
  def of_plugin(plugin) do
    with true <- Code.ensure_loaded?(plugin),
         true <- function_exported?(plugin, :security_checks, 0),
         list when is_list(list) <- safely(fn -> plugin.security_checks() end) do
      Enum.filter(list, &is_atom/1)
    else
      _none -> []
    end
  end

  @doc "Every usable check, resolved, core first, each id once."
  @spec checks() :: [descriptor()]
  def checks do
    sources =
      Enum.map(@core, &{&1, :core}) ++
        Enum.flat_map(Kiln.Plugins.all(), fn plugin ->
          name = plugin_name(plugin)
          Enum.map(of_plugin(plugin), &{&1, {:plugin, name}})
        end) ++
        Enum.map(configured(), &{&1, :config})

    {descriptors, _seen} =
      Enum.reduce(sources, {[], MapSet.new()}, fn {module, source}, {acc, seen} ->
        case resolve(module, source, seen) do
          {:ok, descriptor} -> {[descriptor | acc], MapSet.put(seen, descriptor.id)}
          :skip -> {acc, seen}
        end
      end)

    Enum.reverse(descriptors)
  end

  defp resolve(module, source, seen) do
    case Kiln.Security.Check.describe(module) do
      {:ok, %{id: id} = described} ->
        cond do
          source != :core and String.starts_with?(id, "core.") ->
            Logger.warning(
              "Security posture: #{inspect(module)} takes the reserved id #{inspect(id)}; skipped"
            )

            :skip

          MapSet.member?(seen, id) ->
            Logger.warning(
              "Security posture: #{inspect(module)} repeats the id #{inspect(id)}; the first one registered is used"
            )

            :skip

          true ->
            {:ok,
             described
             |> Map.put(:title, String.replace_invalid(described.title))
             |> Map.update(:description, nil, &valid_text/1)
             |> Map.put(:timeout, clamp(described.timeout))
             |> Map.put(:source, source)}
        end

      {:error, problems} ->
        Logger.warning(
          "Security posture: #{inspect(module)} is not a usable check and is skipped: " <>
            Enum.join(problems, "; ")
        )

        :skip
    end
  end

  @doc "A check's own timeout held to #{@min_timeout}..#{@max_timeout} ms."
  @spec clamp(integer()) :: pos_integer()
  def clamp(ms) when is_integer(ms), do: ms |> max(@min_timeout) |> min(@max_timeout)

  defp configured do
    case Keyword.get(Application.get_env(:kiln_cms, KilnCMS.Security.Posture, []), :checks, []) do
      list when is_list(list) -> Enum.filter(list, &is_atom/1)
      _other -> []
    end
  end

  @doc """
  The name a plugin's checks are listed under: its `name/0`, or its module
  name when that raises, is not a string, or is not valid UTF-8 (which would
  make the report unencodable on the page and at `GET /api/security/posture`).
  """
  @spec plugin_name(module()) :: String.t()
  def plugin_name(plugin) do
    case safely(fn -> plugin.name() end) do
      name when is_binary(name) -> if String.valid?(name), do: name, else: inspect(plugin)
      _unnamed -> inspect(plugin)
    end
  end

  defp valid_text(text) when is_binary(text), do: String.replace_invalid(text)
  defp valid_text(other), do: other

  defp safely(fun) do
    fun.()
  rescue
    _error -> :raised
  catch
    _kind, _reason -> :raised
  end
end
