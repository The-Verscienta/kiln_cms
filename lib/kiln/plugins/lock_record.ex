defmodule Kiln.Plugins.LockRecord.Parser do
  @moduledoc false
  # The pure half of `Kiln.Plugins.LockRecord`, in its own module because the
  # record is built in that module's body at compile time, where its own
  # functions do not exist yet. Defined first in this file so it is loaded by
  # then.

  # The `kiln_plugin` requirement each loaded dependency declares, from the
  # dependency graph Mix resolved for this build (what
  # `mix kiln.plugins.doctor` reads), or `:error` when it is unavailable.
  def read_deps do
    if Code.ensure_loaded?(Mix.Dep) do
      {:ok,
       for(dep <- Mix.Dep.cached(), do: {dep.app, Enum.map(dep.deps, &{&1.app, &1.requirement})})}
    else
      :error
    end
  rescue
    # A compile-time boundary: Mix's graph is undocumented API, and a build
    # must not fail because the health check could not read it. The answer
    # becomes `:unknown`, which the check reports as such.
    _exception -> :error
  end

  def from_lock(lock) when is_map(lock) do
    for {app, entry} <- lock, parsed = parse(to_string(app), entry), into: %{} do
      {to_string(app), parsed}
    end
  end

  def from_deps(:error), do: :unknown

  def from_deps({:ok, declared}) do
    for {app, children} <- declared,
        {:kiln_plugin, requirement} <- children,
        into: %{},
        do: {to_string(app), requirement}
  end

  # The hex tuple grew over Hex's lifetime: 6 elements (no repo), 7 (repo),
  # 8 (outer checksum). The outer checksum is the one hex.pm's API reports.
  defp parse(app, entry) when is_tuple(entry) and tuple_size(entry) >= 6 do
    case Tuple.to_list(entry) do
      [:hex, package, version, _inner, _managers, deps | rest] ->
        %{
          blank(app)
          | source: :hex,
            package: to_string(package),
            version: version,
            repo: Enum.at(rest, 0, "hexpm"),
            outer_checksum: Enum.at(rest, 1),
            sdk_requirement: lock_sdk_requirement(deps)
        }

      _other ->
        parse_git(app, entry)
    end
  end

  defp parse(app, entry) when is_tuple(entry), do: parse_git(app, entry)
  defp parse(_app, _entry), do: nil

  defp parse_git(app, entry) do
    case Tuple.to_list(entry) do
      [:git, url, ref | _rest] when is_binary(url) and is_binary(ref) ->
        %{blank(app) | source: :git, git_url: url, git_ref: ref}

      _other ->
        nil
    end
  end

  defp blank(app) do
    %{
      app: app,
      source: nil,
      package: nil,
      version: nil,
      repo: nil,
      outer_checksum: nil,
      git_url: nil,
      git_ref: nil,
      sdk_requirement: nil
    }
  end

  defp lock_sdk_requirement(deps) when is_list(deps) do
    Enum.find_value(deps, fn
      {:kiln_plugin, requirement, _opts} when is_binary(requirement) -> requirement
      _dep -> nil
    end)
  end

  defp lock_sdk_requirement(_deps), do: nil
end

defmodule Kiln.Plugins.LockRecord do
  @moduledoc """
  What this build's lockfile said about each dependency, captured at compile
  time (#2244).

  A release carries neither `mix.lock` nor `deps/`, so the coordinates the
  plugin health check compares against hex.pm — package, version, repository
  and Hex's outer checksum, or a git URL and commit — have to be recorded while
  the lockfile is still there. They are read once, here, when this module
  compiles, through the project lock reader (`mix kiln.update`'s): the lock is parsed as literal
  data, never evaluated.

  Every hex and git entry is kept, keyed by app name. Which of them are plugins
  is decided at runtime from `Kiln.Plugins.all/0`; filtering here (on a
  `kiln_plugin` dependency, say) would drop a plugin that reaches the SDK
  transitively.

  The lockfile is the project's own: `mix.lock`, or `config/project.lock` while
  an overlay has dependencies (#1967), expanded against the project root rather
  than the working directory. A missing lockfile records nothing.

  ## SDK requirements

  The `kiln_plugin` requirement a hex dependency declares is in its lock entry.
  A git or path dependency's is not, so it is taken from Mix's resolved
  dependency graph (`Mix.Dep.cached()`, the same source
  `mix kiln.plugins.doctor` reads) while compiling. If that graph cannot be
  read, `sdk_requirements/0` is `:unknown` rather than `%{}`: "no plugin
  declared a requirement" and "we could not tell" are different answers, and
  only the first may read as compatible.

  Nothing here touches the network.
  """

  alias Kiln.Plugins.LockRecord.Parser
  alias Mix.Kiln.ProjectLock

  @typedoc """
  One lock entry. `source` is `:hex` or `:git`; hex entries carry `package`,
  `version`, `repo` and `outer_checksum` (`nil` in the older lock shapes that
  predate it), git entries `git_url` and `git_ref`. `sdk_requirement` is the
  entry's own `kiln_plugin` requirement when the lock records one.
  """
  @type entry :: %{
          app: String.t(),
          source: :hex | :git,
          package: String.t() | nil,
          version: String.t() | nil,
          repo: String.t() | nil,
          outer_checksum: String.t() | nil,
          git_url: String.t() | nil,
          git_ref: String.t() | nil,
          sdk_requirement: String.t() | nil
        }

  @typedoc """
  App name to its declared `kiln_plugin` requirement (`nil` when it depends on
  the SDK without a version, as a bare `path:` dependency does), or `:unknown`
  when Mix's dependency graph could not be read at compile time.
  """
  @type sdk_requirements :: %{String.t() => String.t() | nil} | :unknown

  @lock_path Path.expand(
               Mix.Project.config()[:lockfile] || "mix.lock",
               Path.dirname(Mix.Project.project_file())
             )

  @external_resource @lock_path

  @entries @lock_path |> ProjectLock.read() |> Parser.from_lock()
  @sdk_requirements Parser.from_deps(Parser.read_deps())

  @doc false
  # Recompile when the lockfile's content changes (`@external_resource`
  # covers the file), when its *path* moved (an overlay added or removed
  # `config/project_deps.exs`), or when a dependency's declared `kiln_plugin`
  # requirement changed: a path plugin is in no lockfile, so editing its
  # requirement would otherwise leave the old one recorded until a clean build.
  def __mix_recompile__? do
    path =
      Path.expand(
        Mix.Project.config()[:lockfile] || "mix.lock",
        Path.dirname(Mix.Project.project_file())
      )

    path != @lock_path or Parser.from_deps(Parser.read_deps()) != @sdk_requirements
  end

  @doc "Every hex and git entry in this build's lockfile, by app name."
  @spec entries() :: %{String.t() => entry()}
  def entries, do: @entries

  @doc "The entry for `app`, or `nil` when the lock has none (path deps, the core itself)."
  @spec fetch(atom() | nil) :: entry() | nil
  def fetch(nil), do: nil
  def fetch(app) when is_atom(app), do: Map.get(@entries, Atom.to_string(app))

  @doc "See `t:sdk_requirements/0`."
  @spec sdk_requirements() :: sdk_requirements()
  def sdk_requirements, do: @sdk_requirements

  @doc """
  The entries of a parsed lockfile (a map of app name to lock tuple).
  Pure; public for tests.
  """
  @spec from_lock(%{String.t() => tuple()}) :: %{String.t() => entry()}
  defdelegate from_lock(lock), to: Parser

  @doc """
  App name to `kiln_plugin` requirement from Mix's dependency graph
  (`{:ok, [{app, [{child_app, requirement}]}]}`); `:unknown` for `:error`, the
  graph being unreadable. Pure; public for tests.
  """
  @spec from_deps({:ok, [{atom(), [{atom(), String.t() | nil}]}]} | :error) ::
          sdk_requirements()
  defdelegate from_deps(declared), to: Parser
end
