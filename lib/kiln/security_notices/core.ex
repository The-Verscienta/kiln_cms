defmodule Kiln.SecurityNotices.Core do
  @moduledoc """
  Whether a published security notice covers the running core (#2522). Pure:
  the notices and the version are arguments, so every branch is testable with
  literal data. `KilnCMS.Security.Posture.Checks.CoreSecurityNotices` and
  System's Updates card read it.

  A notice concerns the core when one of its packages is `kiln_cms`, the name
  `scripts/publish/security.exs` gives the core: the script writes it for an
  advisory whose vulnerabilities name no package. A feed entry whose own
  `package` field is blank or missing is dropped when the feed is read
  (`Kiln.Plugins.Health.Notices.parse_entries/1`) and never reaches here; the
  script never publishes one. Each notice naming the core is placed against
  the version (`classify/2`), the first rule that applies:

    * `:unplaceable` — its affected versions can't be read (empty, malformed
      or the literal `unknown`);
    * `:outside` — the version is outside every affected range;
    * `:unplaceable` — inside, but the notice names several packages: their
      ranges are joined with no record of whose is whose, so the range that
      matched may be a plugin's (the rule `Kiln.Plugins.Health.Evaluate`
      keeps for plugins);
    * `:affected` — otherwise.

  `affected_versions` alone decides. `patched_versions` is shown to the
  reader ("fixed in …") and never consulted: the publisher drops a line that
  has no fix yet from it, so a version on an unfixed line, or inside a
  regression range that reopened after a fix, could otherwise read as
  patched. GitHub's vulnerable range already excludes the fixed releases; a
  loose range that was never tightened flags a fixed version, which errs on
  the strict side.

  Ranges are matched the way plugin notices are
  (`Kiln.Plugins.Health.Evaluate.parse_affected/1` and `affected?/2`), release
  candidates included.
  """

  alias Kiln.Plugins.Health.Evaluate
  alias Kiln.Plugins.Health.Notice

  # `@core_package` in `scripts/publish/security.exs`; a test keeps them equal.
  @core_packages ["kiln_cms"]

  @typedoc """
  The notices that name the core, by how they place against the version:
  `affected`, `unplaceable` (see `classify/2`), and `considered`, every
  notice that names the core. `version` is the version they were placed
  against, as given.
  """
  @type status :: %{
          version: String.t(),
          affected: [Notice.t()],
          unplaceable: [Notice.t()],
          considered: [Notice.t()]
        }

  @doc "The package names that mean the core in a notice."
  @spec core_packages() :: [String.t()]
  def core_packages, do: @core_packages

  @doc """
  Places every notice that names the core against `version` (the running
  core's, `Kiln.Version.version/0`).

  No notice naming the core is `{:ok, _}` with nothing affected, whatever the
  version. With one, a version that can't be read (or the `"0.0.0"` a build
  without a version reports) is `{:error, :unknown_version}`: never matched,
  never a pass.
  """
  @spec status([Notice.t()], String.t() | nil) :: {:ok, status()} | {:error, :unknown_version}
  def status(notices, version) when is_list(notices) do
    case Enum.filter(notices, &core?/1) do
      [] ->
        {:ok, %{version: version, affected: [], unplaceable: [], considered: []}}

      core ->
        with {:ok, parsed} <- parse_version(version) do
          placed = Enum.group_by(core, &classify(&1, parsed))

          {:ok,
           %{
             version: version,
             affected: Map.get(placed, :affected, []),
             unplaceable: Map.get(placed, :unplaceable, []),
             considered: core
           }}
        end
    end
  end

  @doc "Whether `notice` names the core."
  @spec core?(Notice.t()) :: boolean()
  def core?(%Notice{packages: packages}),
    do: Enum.any?(packages, &((&1 |> String.trim() |> String.downcase()) in @core_packages))

  @doc """
  Where `version` places against one notice: `:affected`, `:outside` or
  `:unplaceable`, as listed in the moduledoc.
  """
  @spec classify(Notice.t(), Version.t()) :: :affected | :outside | :unplaceable
  def classify(%Notice{} = notice, %Version{} = version) do
    case Evaluate.parse_affected(notice.affected) do
      :error ->
        :unplaceable

      {:ok, requirements} ->
        cond do
          not Evaluate.affected?(version, requirements) -> :outside
          length(notice.packages) > 1 -> :unplaceable
          true -> :affected
        end
    end
  end

  defp parse_version(version) when is_binary(version) do
    case version |> String.trim() |> String.trim_leading("v") |> Version.parse() do
      {:ok, %Version{major: 0, minor: 0, patch: 0, pre: []}} -> {:error, :unknown_version}
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, :unknown_version}
    end
  end

  defp parse_version(_version), do: {:error, :unknown_version}
end
