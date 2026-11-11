defmodule KilnCMS.Security.Posture.Checks.PluginHealth do
  @moduledoc """
  `core.plugin_health` (#2244): whether the installed plugins still check out
  (`Kiln.Plugins.Health`), read from its cache only (`Kiln.Plugins.Health.cached/1`),
  so the check never waits on the network. On a cold cache it asks
  `Kiln.Plugins.Health.warm/0` to run the check in the background and answers
  `:unknown` until the answer is cached.

  The worst plugin decides:

    * any `:fail` (the package changed on Hex since this build, a high,
      critical or unrated security notice, retired for security) — `:fail`;
    * any `:warn` (a low or medium notice, not on Hex, retired, no recent
      release, an SDK this Kiln does not bundle) — `:warn`;
    * any `:unknown` (Hex or the notices feed did not answer) — `:unknown`;
    * otherwise `:pass`. A git or path plugin has no registry checksum to
      compare, but its notices and SDK were checked, so it passes with a
      detail line saying how far the check reached. Unknown is reserved for
      checks that could not run.

  Checks turned off is `:n_a` unless the local SDK check (which needs no
  request) finds a problem, which warns. A deployment whose plugins are all
  built from this project is `:n_a`: there is nothing upstream to compare.

  `reasons/1` is also what System → Plugins lists under each plugin, so the
  two surfaces describe a problem in the same words.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Kiln.Plugins.Health
  alias Kiln.Plugins.Health.PluginStatus
  alias Kiln.Plugins.Health.Report
  alias KilnCMS.Security.Posture

  @max_details 10

  @impl Kiln.Security.Check
  def id, do: "core.plugin_health"

  @impl Kiln.Security.Check
  def title, do: gettext("Installed plugins")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "A plugin with a known security problem or a changed package can compromise the whole installation."
      )

  @impl Kiln.Security.Check
  def scope, do: :deployment

  @impl Kiln.Security.Check
  def run(_context) do
    case Health.cached() do
      nil ->
        Health.warm()

        unknown(
          gettext("Checking plugins; reopen this page in a minute."),
          Keyword.put(opts(), :facts, %{pending: true})
        )

      %Report{} = report ->
        result(report)
    end
  end

  @doc """
  The posture answer for a `Kiln.Plugins.Health.Report`. Pure; `run/1` calls
  it with the cached report, and tests with one built from stubbed data.
  """
  @spec result(Report.t()) :: Kiln.Security.Check.Result.t()
  def result(%Report{state: :nothing_to_check}) do
    n_a(gettext("No plugins are installed from Hex, git or a path."), opts())
  end

  def result(%Report{state: :disabled, plugins: plugins}) do
    # Only the local SDK check ran; anything else in a status is "not asked".
    case Enum.filter(plugins, &sdk_problem?/1) do
      [] ->
        n_a(
          gettext(
            "Plugin checks are turned off (KILN_PLUGIN_HEALTH_CHECK=false, or KILN_UPDATE_CHECK=false)."
          ),
          opts()
        )

      problems ->
        warn(
          problem_summary(length(problems)),
          opts(
            details: details(problems, &sdk_reasons/1),
            facts: %{sdk_problems: length(problems)}
          )
        )
    end
  end

  def result(%Report{plugins: plugins} = report) do
    checked = Enum.reject(plugins, &(&1.overall == :not_applicable))
    counts = Enum.frequencies_by(checked, & &1.overall)
    facts = Map.new(~w(fail warn unknown unverifiable ok)a, &{&1, Map.get(counts, &1, 0)})
    failing = Enum.filter(checked, &(&1.overall in [:fail, :warn]))
    unknown = Enum.filter(checked, &(&1.overall == :unknown))

    cond do
      counts[:fail] ->
        fail(problem_summary(length(failing)), opts(details: details(failing), facts: facts))

      counts[:warn] ->
        warn(problem_summary(length(failing)), opts(details: details(failing), facts: facts))

      counts[:unknown] ->
        unknown(
          gettext("Could not reach Hex or the security notices feed. Open System to check."),
          opts(details: details(unknown, &unknown_reason/1), facts: facts)
        )

      true ->
        pass_result(report, facts)
    end
  end

  defp pass_result(report, facts) do
    unverifiable = Map.get(facts, :unverifiable, 0)

    summary =
      if unverifiable == 0,
        do: gettext("Every plugin matches Hex and has no known security notice."),
        else: gettext("No installed plugin has a known security notice or SDK problem.")

    details =
      [
        unverifiable > 0 &&
          ngettext(
            "%{count} plugin comes from git or a path; checked for security notices and SDK support only.",
            "%{count} plugins come from git or a path; checked for security notices and SDK support only.",
            unverifiable
          ),
        report.notices == :disabled &&
          gettext(
            "The security notices feed is turned off; only Hex's own advisories were checked."
          )
      ]
      |> Enum.filter(&is_binary/1)

    pass(summary, opts(details: details, facts: facts))
  end

  @doc """
  Why a plugin is not OK, one translated sentence per reason, in the order
  the rollup weighs them. Empty for a plugin with nothing wrong.
  """
  @spec reasons(PluginStatus.t()) :: [String.t()]
  def reasons(%PluginStatus{} = status) do
    integrity_reasons(status) ++
      notice_reasons(status) ++
      Enum.map(status.abandonment, &abandonment_reason(status, &1))
  end

  defp integrity_reasons(%PluginStatus{integrity: {:mismatch, _}} = status) do
    [
      gettext(
        "%{name}: the package Hex publishes at %{version} differs from the one this release was built from.",
        name: status.name,
        version: status.version
      )
    ]
  end

  defp integrity_reasons(%PluginStatus{integrity: :not_found} = status) do
    [
      gettext("%{name} is not published on Hex at %{version}.",
        name: status.name,
        version: status.version
      )
    ]
  end

  defp integrity_reasons(_status), do: []

  defp notice_reasons(%PluginStatus{advisories: {_state, notices}} = status) do
    Enum.map(notices, fn notice ->
      gettext("%{name} %{version}: security notice %{id} (%{severity}).",
        name: status.name,
        version: status.version,
        id: notice.id,
        severity: severity(notice.severity)
      )
    end)
  end

  defp abandonment_reason(status, {:retired, reason, _message}) do
    gettext("%{name} %{version} is retired on Hex (%{reason}).",
      name: status.name,
      version: status.version,
      reason: retirement(reason)
    )
  end

  defp abandonment_reason(status, {:stale, at}) do
    gettext("%{name} has had no release on Hex since %{date}.",
      name: status.name,
      date: Calendar.strftime(at, "%Y-%m-%d")
    )
  end

  defp abandonment_reason(status, {:sdk_unsupported, requirement, bundled}) do
    gettext("%{name} needs kiln_plugin %{requirement}; this Kiln bundles %{version}.",
      name: status.name,
      requirement: requirement,
      version: bundled
    )
  end

  defp abandonment_reason(status, {:sdk_requirement_invalid, requirement}) do
    gettext("%{name} declares a kiln_plugin requirement that can't be read: %{requirement}.",
      name: status.name,
      requirement: requirement
    )
  end

  defp sdk_reasons(status) do
    status.abandonment
    |> Enum.filter(&sdk_reason?/1)
    |> Enum.map(&abandonment_reason(status, &1))
  end

  defp unknown_reason(status) do
    [gettext("%{name} could not be checked.", name: status.name)]
  end

  defp sdk_problem?(%PluginStatus{abandonment: reasons}), do: Enum.any?(reasons, &sdk_reason?/1)

  defp sdk_reason?({:sdk_unsupported, _requirement, _bundled}), do: true
  defp sdk_reason?({:sdk_requirement_invalid, _requirement}), do: true
  defp sdk_reason?(_reason), do: false

  defp severity(:low), do: gettext("low")
  defp severity(:medium), do: gettext("medium")
  defp severity(:high), do: gettext("high")
  defp severity(:critical), do: gettext("critical")
  defp severity(_unknown), do: gettext("severity unknown")

  defp retirement(:security), do: gettext("security")
  defp retirement(:deprecated), do: gettext("deprecated")
  defp retirement(:invalid), do: gettext("invalid")
  defp retirement(:renamed), do: gettext("renamed")
  defp retirement(_other), do: gettext("other")

  defp problem_summary(count) do
    ngettext("%{count} plugin has problems.", "%{count} plugins have problems.", count)
  end

  defp details(statuses, fun \\ &reasons/1) do
    statuses |> Enum.flat_map(fun) |> Enum.take(@max_details)
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [fix_path: "/editor/system", docs_url: Posture.docs_url("installed-plugins")],
      extra
    )
  end
end
