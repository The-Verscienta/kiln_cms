defmodule Kiln.Plugins.Health.Evaluate do
  @moduledoc """
  The pure core of the plugin health check (#2244): installed plugins plus
  whatever the fetchers brought back, in; one `Kiln.Plugins.Health.PluginStatus`
  per plugin, out. No IO, no gettext, no application env — every input is an
  argument, so every branch is testable with literal data.

  ## Unknown is never OK

  A source that could not be asked, or answered with something unusable, makes
  the dimension it feeds `:unknown`, and `rollup/1` only answers `:ok` when
  every dimension positively said so. A source that is *turned off* (the
  notices feed for a fork, or `:disabled`) contributes nothing instead: it was
  a choice, not a failure. Integrity is the exception, since its only source
  is Hex: a disabled check leaves it `:disabled`, which rolls up as unknown.

  ## The checksum comparison is mutation-tested

  `integrity/2` compares the lock's outer checksum with the one hex.pm
  reports for that release. The test replaces one character of a real
  checksum and requires `{:mismatch, _}` and an overall `:fail`. Replacing the
  comparison with a constant `:ok` makes that test fail; it was run that way
  once when this module was written, so the test is known to be able to fail.

  What a mismatch means, and does not: `mix deps.get` already refuses a lock
  whose checksum differs from the signed registry, so a mismatch at runtime
  says Hex's record changed after this build (a replaced or reverted release,
  or a compromised registry), the build resolved against a mirror or offline
  cache, or the lock was edited by hand. It says nothing about the compiled
  code in the running release, which nothing here re-hashes.
  """

  alias Kiln.Plugins.Health.Installed
  alias Kiln.Plugins.Health.Notice
  alias Kiln.Plugins.Health.Notices
  alias Kiln.Plugins.Health.PluginStatus

  @typedoc """
  What `Kiln.Plugins.Health.Hex.fetch/3` answered for one package: both
  documents, a definitive 404, any other failure, or `:disabled`.
  """
  @type hex_result ::
          {:ok, %{package: map(), release: map()}}
          | {:error, :not_found}
          | {:error, term()}
          | :disabled

  @typedoc """
  Everything fetched for one check: Hex results by package name (`:disabled`
  when checks are off), and the security notices feed.
  """
  @type fetched :: %{
          hex: %{String.t() => hex_result()} | :disabled,
          notices: {:ok, [Notice.t()]} | {:error, term()} | :disabled
        }

  @hex_repo "hexpm"

  @retirement_reasons %{
    "security" => :security,
    "deprecated" => :deprecated,
    "invalid" => :invalid,
    "renamed" => :renamed,
    "other" => :other
  }

  @doc """
  One status per installed plugin, in the order given.

  Options (all required): `:now` (a `DateTime`), `:stale_after_months` (a
  positive integer) and `:sdk_version` (the `kiln_plugin` version this core
  bundles, or `nil` if unknown).
  """
  @spec evaluate([Installed.t()], fetched(), keyword()) :: [PluginStatus.t()]
  def evaluate(installed, fetched, opts) do
    Enum.map(installed, &status(&1, fetched, opts))
  end

  defp status(%Installed{} = installed, fetched, opts) do
    hex = hex_result(installed, fetched)
    {abandonment, known?} = abandonment(installed, hex, opts)

    status = %PluginStatus{
      plugin: installed.plugin,
      name: installed.name,
      source: installed.source,
      package: installed.package,
      version: installed.version,
      latest_version: latest_version(hex),
      sdk_requirement: installed.sdk_requirement,
      outer_checksum: installed.outer_checksum,
      git_ref: installed.git_ref,
      integrity: integrity(installed, hex),
      advisories: advisories(installed, hex, Map.get(fetched, :notices, :disabled)),
      abandonment: abandonment,
      abandonment_known?: known?
    }

    %{status | overall: rollup(status)}
  end

  # `:not_applicable` for every plugin Hex cannot speak for — anything but a
  # plugin locked from the public hex.pm repository.
  defp hex_result(%Installed{source: :hex, repo: @hex_repo, package: package}, fetched) do
    case Map.get(fetched, :hex, :disabled) do
      :disabled -> :disabled
      results when is_map(results) -> Map.get(results, package, {:error, :not_fetched})
    end
  end

  defp hex_result(_installed, _fetched), do: :not_applicable

  defp latest_version({:ok, %{package: package}}) when is_map(package) do
    case package["latest_stable_version"] || package["latest_version"] do
      version when is_binary(version) -> version
      _ -> nil
    end
  end

  defp latest_version(_hex), do: nil

  # ---------------------------------------------------------------------------
  # Integrity

  @doc """
  Whether the locked checksum is the one Hex publishes for that release. See
  `t:Kiln.Plugins.Health.PluginStatus.integrity/0`.
  """
  @spec integrity(Installed.t(), hex_result() | :not_applicable) ::
          PluginStatus.integrity()
  def integrity(%Installed{source: :overlay}, _hex), do: :not_applicable
  def integrity(%Installed{source: :git}, _hex), do: {:unverifiable, :git}
  def integrity(%Installed{source: :path}, _hex), do: {:unverifiable, :path}
  def integrity(%Installed{source: :unknown}, _hex), do: {:unverifiable, :unknown_source}

  def integrity(%Installed{source: :hex, repo: repo}, _hex) when repo != @hex_repo,
    do: {:unverifiable, :private_repo}

  def integrity(%Installed{source: :hex, outer_checksum: nil}, _hex),
    do: {:unverifiable, :no_checksum}

  def integrity(%Installed{source: :hex}, :disabled), do: :disabled
  def integrity(%Installed{source: :hex}, {:error, :not_found}), do: :not_found

  def integrity(%Installed{source: :hex, outer_checksum: locked}, {:ok, %{release: release}}),
    do: compare_checksum(locked, release)

  def integrity(%Installed{source: :hex}, _failed_or_malformed), do: :unknown

  # Hex prints checksums in lowercase hex, but nothing promises it, and a case
  # difference is not a different package.
  defp compare_checksum(locked, %{"checksum" => registry}) when is_binary(registry) do
    if String.downcase(registry) == String.downcase(locked),
      do: :ok,
      else: {:mismatch, %{locked: locked, registry: registry}}
  end

  defp compare_checksum(_locked, _release), do: :unknown

  # ---------------------------------------------------------------------------
  # Abandonment

  @doc """
  Retirement, staleness and SDK support, as `{reasons, known?}`.

  Retirement and staleness come from Hex, so only a hex.pm plugin has them;
  for a git or path plugin they are "not checked", which does not make the
  answer unknown. The SDK requirement is checked for every plugin not built
  from this project, and an unreadable requirement does.
  """
  @spec abandonment(Installed.t(), hex_result() | :not_applicable, keyword()) ::
          {[PluginStatus.abandonment_reason()], boolean()}
  def abandonment(%Installed{source: :overlay}, _hex, _opts), do: {[], true}

  def abandonment(%Installed{} = installed, hex, opts) do
    {hex_reasons, hex_known?} = hex_abandonment(hex, opts)

    {sdk_reasons, sdk_known?} =
      installed
      |> sdk_requirement(hex)
      |> sdk(Keyword.get(opts, :sdk_version))
      |> sdk_reasons()

    {hex_reasons ++ sdk_reasons, hex_known? and sdk_known?}
  end

  defp hex_abandonment(:not_applicable, _opts), do: {[], true}

  defp hex_abandonment({:ok, %{package: package, release: release}}, opts) do
    {stale, stale_known?} = stale(package, opts)
    {retired(release) ++ stale, stale_known?}
  end

  defp hex_abandonment(_unavailable, _opts), do: {[], false}

  defp retired(%{"retirement" => %{"reason" => reason} = retirement}) do
    [{:retired, Map.get(@retirement_reasons, reason, :other), retirement["message"]}]
  end

  defp retired(_release), do: []

  # The newest release of the package, not of the installed version: a plugin
  # one minor behind a maintained line is not abandoned.
  defp stale(%{"releases" => releases}, opts) when is_list(releases) do
    newest =
      releases
      |> Enum.flat_map(&release_inserted_at/1)
      |> Enum.max(DateTime, fn -> nil end)

    case newest do
      nil ->
        {[], false}

      newest ->
        months = Keyword.fetch!(opts, :stale_after_months)
        threshold = DateTime.shift(Keyword.fetch!(opts, :now), month: -months)

        if DateTime.before?(newest, threshold), do: {[{:stale, newest}], true}, else: {[], true}
    end
  end

  defp stale(_package, _opts), do: {[], false}

  defp release_inserted_at(%{"inserted_at" => raw}) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, at, _offset} -> [at]
      _ -> []
    end
  end

  defp release_inserted_at(_release), do: []

  # The lock's (or Mix's) requirement first. A hex plugin whose lock entry did
  # not record one falls back to the release's own metadata; if Hex could not
  # be asked, the requirement is unknown rather than "none".
  defp sdk_requirement(%Installed{source: :hex, sdk_requirement: nil}, hex) do
    case hex do
      {:ok, %{release: release}} -> hex_sdk_requirement(release)
      :not_applicable -> nil
      _unavailable -> :unknown
    end
  end

  defp sdk_requirement(%Installed{sdk_requirement: requirement}, _hex), do: requirement

  defp hex_sdk_requirement(%{"requirements" => %{"kiln_plugin" => %{"requirement" => req}}})
       when is_binary(req),
       do: req

  defp hex_sdk_requirement(_release), do: nil

  defp sdk_reasons(:ok), do: {[], true}
  defp sdk_reasons(:unknown), do: {[], false}
  defp sdk_reasons({:unsatisfied, req, bundled}), do: {[{:sdk_unsupported, req, bundled}], true}
  defp sdk_reasons({:invalid, req}), do: {[{:sdk_requirement_invalid, req}], true}

  @doc """
  Whether a plugin's `kiln_plugin` requirement accepts the bundled SDK:
  `:ok` (or no requirement), `{:unsatisfied, requirement, bundled}`,
  `{:invalid, requirement}`, or `:unknown` when either side is unknown.

  Matched the way `mix kiln.plugins.doctor` matches it (pre-releases of the
  bundled SDK only satisfy a requirement that names one), so the page and the
  doctor never disagree.
  """
  @spec sdk(String.t() | nil | :unknown, String.t() | nil) ::
          :ok | {:unsatisfied, String.t(), String.t()} | {:invalid, String.t()} | :unknown
  def sdk(nil, _bundled), do: :ok
  def sdk(:unknown, _bundled), do: :unknown
  def sdk(_requirement, nil), do: :unknown

  def sdk(requirement, bundled) when is_binary(requirement) and is_binary(bundled) do
    case {Version.parse_requirement(requirement), Version.parse(bundled)} do
      {:error, _bundled} ->
        {:invalid, requirement}

      {_requirement, :error} ->
        :unknown

      {{:ok, parsed}, {:ok, version}} ->
        if Version.match?(version, parsed), do: :ok, else: {:unsatisfied, requirement, bundled}
    end
  end

  # ---------------------------------------------------------------------------
  # Advisories

  @doc """
  The security notices that cover the installed version.

  A notice concerns a plugin when one of its packages is the plugin's Hex
  package or app name (case-insensitively). kilncms.dev notices are matched
  by version range (`affected?/2`); Hex's are listed on the installed release
  already. The same advisory from both sources is kept once, as Hex's.
  """
  @spec advisories(
          Installed.t(),
          hex_result() | :not_applicable,
          {:ok, [Notice.t()]} | {:error, term()} | :disabled
        ) :: PluginStatus.advisories()
  def advisories(%Installed{source: :overlay}, _hex, _notices), do: {:ok, []}

  def advisories(%Installed{} = installed, hex, notices) do
    {hex_state, hex_notices} = hex_advisories(installed, hex)
    {kiln_state, kiln_notices} = kiln_advisories(installed, notices)

    hex_ids = hex_notices |> Enum.flat_map(&Notice.ids/1) |> MapSet.new()

    kiln_notices =
      Enum.reject(kiln_notices, fn notice ->
        Enum.any?(Notice.ids(notice), &MapSet.member?(hex_ids, &1))
      end)

    state = if :unknown in [hex_state, kiln_state], do: :unknown, else: :ok
    {state, hex_notices ++ kiln_notices}
  end

  defp hex_advisories(_installed, :not_applicable), do: {:ok, []}
  defp hex_advisories(_installed, :disabled), do: {:ok, []}
  defp hex_advisories(_installed, {:error, :not_found}), do: {:ok, []}

  defp hex_advisories(%Installed{package: package}, {:ok, %{release: release}}),
    do: {:ok, Notices.from_hex_release(release, package)}

  defp hex_advisories(_installed, _failed), do: {:unknown, []}

  defp kiln_advisories(_installed, :disabled), do: {:ok, []}
  defp kiln_advisories(_installed, {:error, _reason}), do: {:unknown, []}

  defp kiln_advisories(%Installed{} = installed, {:ok, notices}) do
    candidates = candidates(installed)

    case Enum.filter(notices, &names_any?(&1, candidates)) do
      [] -> {:ok, []}
      named -> match_versions(named, installed.version)
    end
  end

  # A notice that names the plugin but cannot be placed against its version —
  # the range is unreadable, or the installed version is — makes the answer
  # unknown. It is not listed as matched: "might apply" is not "applies".
  defp match_versions(named, version) do
    case parse_version(version) do
      {:ok, version} -> Enum.reduce(named, {:ok, []}, &match_notice(&1, version, &2))
      :error -> {:unknown, []}
    end
  end

  # A notice naming several packages carries their ranges joined, with no
  # record of which range is whose (`scripts/publish/security.exs`). Outside
  # every range is still a sound "not affected"; inside one may be another
  # package's range, so it is unknown rather than a match — a patched plugin
  # must not fail on the core's range.
  defp match_notice(notice, version, {state, matched}) do
    case {parse_affected(notice.affected), notice.packages} do
      {:error, _packages} ->
        {:unknown, matched}

      {{:ok, requirements}, packages} ->
        cond do
          not affected?(version, requirements) -> {state, matched}
          length(packages) > 1 -> {:unknown, matched}
          true -> {state, matched ++ [notice]}
        end
    end
  end

  defp parse_version(version) when is_binary(version),
    do: version |> String.trim() |> String.trim_leading("v") |> Version.parse()

  defp parse_version(_version), do: :error

  defp candidates(%Installed{package: package, app: app}) do
    [package, app && Atom.to_string(app)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp names_any?(%Notice{packages: packages}, candidates),
    do: Enum.any?(packages, &(String.downcase(&1) in candidates))

  @doc """
  Parses a kilncms.dev `affected_versions` text into requirements, any one of
  which matching means affected.

  `;` (and ` or `, `||`) separate alternatives; within one, `,` and ` and `
  join bounds. `= 1.2.0` and a bare `1.2.0` mean exactly that version, and a
  short version (`< 2.0`) is padded to three parts (`~>` keeps its own
  meaning). `:error` for anything else, including the literal `unknown` the
  publishing script writes when the range is not known.
  """
  @spec parse_affected(String.t() | nil) :: {:ok, [Version.Requirement.t()]} | :error
  def parse_affected(text) when is_binary(text) do
    clauses =
      text
      |> String.split(~r/;|\s+or\s+|\|\|/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if clauses == [], do: :error, else: map_ok(clauses, &parse_clause/1)
  end

  def parse_affected(_text), do: :error

  @bound ~r/\A(>=|<=|==|!=|~>|>|<|=)?\s*v?(\d+(?:\.\d+){0,2})(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?\z/

  defp parse_clause(clause) do
    bounds =
      clause
      |> String.split(~r/,|\s+and\s+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with [_ | _] <- bounds,
         {:ok, normalized} <- normalize_bounds(bounds) do
      Version.parse_requirement(Enum.join(normalized, " and "))
    else
      _ -> :error
    end
  end

  defp normalize_bounds(bounds) do
    map_ok(bounds, fn bound ->
      case Regex.run(@bound, bound, capture: :all_but_first) do
        nil -> :error
        captures -> {:ok, normalize_bound(captures)}
      end
    end)
  end

  # `{:ok, results}` when `fun` answers `{:ok, _}` for every element, else `:error`.
  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn element, {:ok, acc} ->
      case fun.(element) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp normalize_bound([op, version | rest]) do
    suffix = Enum.join(rest)

    case op do
      "~>" -> "~> #{version}#{suffix}"
      op when op in ["", "="] -> "== #{pad(version)}#{suffix}"
      op -> "#{op} #{pad(version)}#{suffix}"
    end
  end

  defp pad(version) do
    parts = String.split(version, ".")
    Enum.join(parts ++ List.duplicate("0", 3 - length(parts)), ".")
  end

  @doc """
  Whether `version` falls in any of `requirements`. Pre-releases match
  (`allow_pre: true`): `1.5.0-pre1` is inside `>= 1.4.1 and <= 1.5.0-pre1`,
  and an advisory that excluded pre-releases by default would miss exactly
  the release candidates people test on.
  """
  @spec affected?(Version.t() | String.t(), [Version.Requirement.t()]) :: boolean()
  def affected?(version, requirements),
    do: Enum.any?(requirements, &Version.match?(version, &1, allow_pre: true))

  # ---------------------------------------------------------------------------
  # Rollup

  @doc """
  One word for a plugin, the first that applies:

    * `:fail` — the checksum changed on Hex; a matched notice is high,
      critical or of unknown severity; or Hex retired the release for
      security;
    * `:warn` — Hex has no such release; a matched notice is low or medium;
      any other retirement, staleness or SDK problem;
    * `:unknown` — a source that applies did not answer, or is disabled for
      integrity;
    * `:unverifiable` — a git, path or private-repo plugin with nothing else
      wrong;
    * `:not_applicable` — built from this project;
    * `:ok` — only when integrity is `:ok`, no notice matched and abandonment
      is known and empty. Anything else that reaches here is `:unknown`.
  """
  @spec rollup(PluginStatus.t()) :: PluginStatus.overall()
  def rollup(%PluginStatus{} = status) do
    cond do
      fail?(status) -> :fail
      warn?(status) -> :warn
      unknown?(status) -> :unknown
      match?({:unverifiable, _}, status.integrity) -> :unverifiable
      status.integrity == :not_applicable -> :not_applicable
      ok?(status) -> :ok
      true -> :unknown
    end
  end

  defp fail?(status) do
    match?({:mismatch, _}, status.integrity) or
      Enum.any?(notices(status), &(&1.severity in [:high, :critical, :unknown])) or
      Enum.any?(status.abandonment, &match?({:retired, :security, _}, &1))
  end

  defp warn?(status) do
    status.integrity == :not_found or
      Enum.any?(notices(status), &(&1.severity in [:low, :medium])) or
      status.abandonment != []
  end

  defp unknown?(status) do
    status.integrity in [:unknown, :disabled] or
      match?({:unknown, _}, status.advisories) or
      not status.abandonment_known?
  end

  defp ok?(status) do
    status.integrity == :ok and status.advisories == {:ok, []} and
      status.abandonment_known? and status.abandonment == []
  end

  defp notices(%PluginStatus{advisories: {_state, notices}}), do: notices
end
