defmodule Kiln.Plugins.Health.Installed do
  @moduledoc """
  One installed plugin as the health check (#2244) sees it: where it came from
  and the coordinates that source can be checked against.

  `source` is

    * `:hex` — a Hex dependency, with the package, version, repository and
      outer checksum this build's lockfile recorded (`Kiln.Plugins.LockRecord`);
    * `:git` — a git dependency, pinned to a commit Hex knows nothing about;
    * `:path` — a `path:` dependency, which no lockfile records;
    * `:overlay` — a module compiled into the `:kiln_cms` app itself (a
      `projects/` overlay or the test fixture): built from this project, so
      there is nothing upstream to compare it with;
    * `:unknown` — the module belongs to no loaded application.

  `sdk_requirement` is the plugin's `kiln_plugin` requirement: a string, `nil`
  when it declares none, or `:unknown` when it could not be read.
  """

  alias Kiln.Plugins.LockRecord

  @enforce_keys [:plugin, :name, :source]
  defstruct [
    :plugin,
    :name,
    :app,
    :source,
    :package,
    :version,
    :repo,
    :outer_checksum,
    :git_url,
    :git_ref,
    :sdk_requirement
  ]

  @type source :: :hex | :git | :path | :overlay | :unknown

  @type t :: %__MODULE__{
          plugin: module(),
          name: String.t(),
          app: atom() | nil,
          source: source(),
          package: String.t() | nil,
          version: String.t() | nil,
          repo: String.t() | nil,
          outer_checksum: String.t() | nil,
          git_url: String.t() | nil,
          git_ref: String.t() | nil,
          sdk_requirement: String.t() | nil | :unknown
        }

  @doc "Every plugin in `Kiln.Plugins.all/0`, classified. No network."
  @spec all() :: [t()]
  def all do
    sdk_requirements = LockRecord.sdk_requirements()

    for plugin <- Kiln.Plugins.all() do
      application = :application.get_application(plugin)

      build(plugin, application, lock_entry(application), %{
        sdk_requirements: sdk_requirements,
        vsn: app_vsn(application),
        name: plugin.name(),
        declared_version: plugin.version()
      })
    end
  end

  defp lock_entry({:ok, app}), do: LockRecord.fetch(app)
  defp lock_entry(:undefined), do: nil

  defp app_vsn({:ok, app}) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp app_vsn(:undefined), do: nil

  @doc """
  Classifies one plugin from facts gathered elsewhere. Pure; public for tests.

    * `application` — `:application.get_application/1`'s answer for the module;
    * `lock_entry` — its `Kiln.Plugins.LockRecord` entry, or `nil`;
    * `facts` — `:sdk_requirements` (`Kiln.Plugins.LockRecord.sdk_requirements/0`),
      `:vsn` (the application's version), `:name` and `:declared_version` (the
      plugin's own `name/0` and `version/0`).

  The version is the lock's for a hex plugin (what the checksum belongs to),
  else the application's, else what the plugin declares.
  """
  @spec build(module(), {:ok, atom()} | :undefined, LockRecord.entry() | nil, map()) :: t()
  def build(plugin, application, lock_entry, facts) do
    base = %__MODULE__{plugin: plugin, name: facts[:name] || inspect(plugin), source: :unknown}

    case {application, lock_entry} do
      {{:ok, :kiln_cms}, _entry} ->
        %{base | app: :kiln_cms, source: :overlay, version: local_version(facts)}

      {{:ok, app}, %{source: :hex} = entry} ->
        %{
          base
          | app: app,
            source: :hex,
            package: entry.package,
            version: entry.version,
            repo: entry.repo,
            outer_checksum: entry.outer_checksum,
            sdk_requirement: entry.sdk_requirement || dep_requirement(app, facts, nil)
        }

      {{:ok, app}, %{source: :git} = entry} ->
        %{
          base
          | app: app,
            source: :git,
            version: local_version(facts),
            git_url: entry.git_url,
            git_ref: entry.git_ref,
            sdk_requirement: dep_requirement(app, facts, :unknown)
        }

      {{:ok, app}, nil} ->
        %{
          base
          | app: app,
            source: :path,
            version: local_version(facts),
            sdk_requirement: dep_requirement(app, facts, :unknown)
        }

      {:undefined, _entry} ->
        %{base | version: local_version(facts), sdk_requirement: :unknown}
    end
  end

  defp local_version(facts), do: facts[:vsn] || facts[:declared_version]

  # Mix's graph, read at compile time. A dependency that does not appear in it
  # declares no kiln_plugin requirement, which is `nil` (nothing to check); the
  # whole graph being unreadable is `if_unreadable`. For a hex plugin that is
  # `nil` because Hex's release metadata supplies the fallback.
  defp dep_requirement(_app, %{sdk_requirements: :unknown}, if_unreadable), do: if_unreadable

  defp dep_requirement(app, %{sdk_requirements: requirements}, _if_unreadable)
       when is_map(requirements),
       do: Map.get(requirements, Atom.to_string(app))

  defp dep_requirement(_app, _facts, if_unreadable), do: if_unreadable
end
