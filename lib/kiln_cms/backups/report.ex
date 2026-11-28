defmodule KilnCMS.Backups.Report do
  @moduledoc """
  What a backup report says about one run (#2229): the email
  (`KilnCMS.Backups.ReportMail`) and the bell row's excerpt
  (`KilnCMS.Backups.ReportWorker`) are both built from it, so they cannot
  say different things.

  `build/3` reads nothing but its arguments and the instance settings it is
  given: the run, the schedules it ran for, and the secrets to remove.

  ## Credentials redacted, display-sanitized

  Every piece of text taken from the run goes through
  `KilnCMS.Backups.Redact` again, with the database password
  `KilnCMS.Backups.LogText.read_env/0` derives (as the Log tab does, ADR
  0092), and through `LogText.sanitize_display/1`: control characters and
  bidirectional overrides become U+FFFD. Error lines are capped at #{300}
  characters, destination labels at #{200}.

  The limit is the Log tab's: a secret is removed literally only when this
  process knows it now, and a destination's credentials by pattern (URL
  userinfo, `key=value`) or by the destination's own call
  (`KilnCMS.Backups.Destination.call/4` scrubs its secrets from what an
  adapter returns before it is stored). An error line may still name a path
  or a host: the report leaves the instance by mail, through the instance
  relay.

  Left out on purpose: file paths and directories, checksums, destination
  keys (an rclone remote's name), the ping URL, and any person's name or
  address.

  ## Classes

  `classify/1` says what kind of report a run gets:

    * `:failed`: the run failed, or it succeeded but no off-site
      destination was reached (every destination failed, or the stored
      destinations couldn't be read and there was no other);
    * `:partial`: it succeeded and reached only some of its destinations;
    * `:succeeded`, `:skipped`, `:canceled`: as the run's status says.

  A run still `running`, or with a status this release doesn't know, has
  none (`nil`).
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Log, LogText, Recorder, Redact, Run, RunDestination}
  alias KilnCMS.Types.UnknownAtom
  alias KilnCMSWeb.Plugs.ConsoleHost

  @max_line 300
  @max_label 200
  @max_site 200
  @max_lines 5

  @type class :: :failed | :partial | :succeeded | :skipped | :canceled

  @type destination :: %{
          label: String.t(),
          status: String.t(),
          files_ok: non_neg_integer(),
          files_total: non_neg_integer(),
          permanent: boolean(),
          error: String.t() | nil
        }

  @type t :: %__MODULE__{
          run_id: String.t(),
          class: class(),
          status: atom(),
          recovered?: boolean(),
          resumed_since?: boolean(),
          stamp: String.t(),
          origin: atom(),
          trigger: String.t(),
          schedules: [String.t()],
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          duration_s: non_neg_integer() | nil,
          components: [String.t()],
          sizes: %{optional(String.t()) => non_neg_integer()},
          media_parts: non_neg_integer(),
          verified: boolean() | nil,
          destinations: [destination()],
          errors: [String.t()],
          truncated?: boolean(),
          site_name: String.t(),
          run_url: String.t(),
          log_url: String.t()
        }

  defstruct [
    :run_id,
    :class,
    :status,
    :stamp,
    :origin,
    :trigger,
    :started_at,
    :finished_at,
    :duration_s,
    :verified,
    :site_name,
    :run_url,
    :log_url,
    recovered?: false,
    resumed_since?: false,
    schedules: [],
    components: [],
    sizes: %{},
    media_parts: 0,
    destinations: [],
    errors: [],
    truncated?: false
  ]

  @doc "Every report class."
  @spec classes() :: [class()]
  def classes, do: [:failed, :partial, :succeeded, :skipped, :canceled]

  @doc "The report class of `run`, or nil when it has none (see the moduledoc)."
  @spec classify(Run.t()) :: class() | nil
  def classify(%Run{status: :failed}), do: :failed
  def classify(%Run{status: :skipped}), do: :skipped
  def classify(%Run{status: :canceled}), do: :canceled

  def classify(%Run{status: :succeeded} = run) do
    cond do
      Recorder.unreadable_only?(run.destinations) -> :failed
      Backups.run_offsite_state(run) == :failed -> :failed
      Backups.run_offsite_state(run) == :partial -> :partial
      true -> :succeeded
    end
  end

  def classify(_run), do: nil

  @doc """
  Whether `run` is a recovery: it ended `failed` once (`last_failed_at`,
  which a resume keeps) and has now succeeded, on- and off-site or partly
  off-site. An in-app run was resumed; an imported one was recorded as
  Interrupted and turned out to have finished after all.
  """
  @spec recovered?(Run.t()) :: boolean()
  def recovered?(%Run{status: :succeeded, last_failed_at: %DateTime{}} = run),
    do: classify(run) in [:succeeded, :partial]

  def recovered?(_run), do: false

  @doc """
  The report on `run`, which ran for `schedules` (the
  `KilnCMS.Backups.Schedule` rows of its `schedule_ids` that still exist).

  Options: `:resumed_since?` (a failure reported after the run was resumed,
  `KilnCMS.Backups.ReportWorker.current_run/2`), `:env` (the secrets to remove, `LogText.read_env/0` by default),
  `:site_name` and `:org` (the instance's site name and the default org, for
  the links; read when not given).
  """
  @spec build(Run.t(), [map()], keyword()) :: t()
  def build(%Run{} = run, schedules, opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &LogText.read_env/0)
    org = Keyword.get_lazy(opts, :org, &default_org/0)
    {errors, truncated?} = error_lines(run, env)

    %__MODULE__{
      run_id: run.id,
      class: classify(run),
      status: run.status,
      recovered?: recovered?(run),
      resumed_since?: Keyword.get(opts, :resumed_since?, false),
      stamp: run.stamp,
      origin: run.origin,
      trigger: LogText.trigger(run.trigger, env),
      schedules: schedule_texts(run, schedules),
      started_at: run.started_at,
      finished_at: run.finished_at,
      duration_s: duration(run),
      components: Enum.map(run.components, &text/1),
      sizes: sizes(run.artifacts),
      media_parts: media_parts(run.artifacts),
      verified: verified(run.artifacts),
      destinations: Enum.map(run.destinations, &destination(&1, env)),
      errors: errors,
      truncated?: truncated?,
      site_name:
        opts
        |> Keyword.get_lazy(:site_name, fn -> site_name(org) end)
        |> one_line(env, @max_site),
      run_url: url(~s|/editor/backups?run=#{run.id}|, org),
      log_url: url(~s|/editor/backups/log?run=#{run.id}|, org)
    }
  end

  @doc """
  What the run was for, as one line: its schedules' cadences, or its trigger
  (`"manual"`, `"cron"`, an operator's `BACKUP_TRIGGER`) when it had none.
  """
  @spec what(t()) :: String.t()
  def what(%__MODULE__{schedules: [_ | _] = schedules}), do: Enum.join(schedules, "; ")
  def what(%__MODULE__{trigger: trigger}), do: trigger

  @doc """
  The bell row's English excerpt (#2229): the stamp, what the run was for,
  and the first error line or how many destinations were reached. At most
  #{@max_label} characters, one line.
  """
  @spec excerpt(t()) :: String.t()
  def excerpt(%__MODULE__{} = report) do
    detail =
      case {report.class, report.errors} do
        {:partial, _errors} -> reached(report)
        {_class, [first | _]} -> first
        {_class, []} -> reached(report)
      end

    [report.stamp, "(" <> what(report) <> ")", detail]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> String.replace("\n", " ")
    |> String.slice(0, @max_label)
  end

  @doc "How many destinations the run reached, in words; nil when it had none."
  @spec reached(t()) :: String.t() | nil
  def reached(%__MODULE__{destinations: []}), do: nil

  def reached(%__MODULE__{destinations: destinations}) do
    counted = Enum.reject(destinations, &(&1.status == "skipped"))
    ok = Enum.count(counted, &(&1.status == "ok"))
    "reached #{ok} of #{length(counted)} off-site destinations"
  end

  @doc "The bell row's `details`: which run, and what kind of report."
  @spec details(t()) :: map()
  def details(%__MODULE__{} = report) do
    %{
      "run_id" => report.run_id,
      "stamp" => report.stamp,
      "class" => Atom.to_string(report.class),
      "recovered" => report.recovered?
    }
  end

  # The first lines of the run's error, then the first `:error` entries of
  # its log, each one line and capped. `truncated?` when either had more.
  defp error_lines(run, env) do
    error =
      case LogText.error(run, env) do
        nil -> []
        text -> text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end

    logged =
      run
      |> LogText.entries(:error, env)
      |> Enum.reject(&Log.marker?/1)
      |> Enum.map(&(&1.message |> String.replace("\n", " ") |> String.trim()))
      |> Enum.reject(&(&1 == ""))

    lines =
      Enum.map(Enum.take(error, @max_lines) ++ Enum.take(logged, @max_lines), &cap/1)

    {lines, length(error) > @max_lines or length(logged) > @max_lines}
  end

  defp destination(%RunDestination{} = entry, env) do
    %{
      label: label(entry, env),
      status: text(entry.status),
      files_ok: entry.files_ok || 0,
      files_total: entry.files_total || 0,
      permanent: entry.permanent == true,
      error: first_line(entry.error, env)
    }
  end

  # The unreadable entry names no destination; every other one shows its
  # stored label, never its key (an rclone key carries the remote's name).
  defp label(%RunDestination{key: key} = entry, env) do
    cond do
      key == RunDestination.unreadable_key() ->
        "The stored destinations (couldn't be read)"

      is_binary(entry.label) and String.trim(entry.label) != "" ->
        one_line(entry.label, env, @max_label)

      is_binary(entry.kind) ->
        one_line("An off-site destination (#{entry.kind})", env, @max_label)

      true ->
        "An off-site destination"
    end
  end

  defp first_line(nil, _env), do: nil

  defp first_line(text, env) do
    text
    |> Redact.text(env, @max_line * 4)
    |> LogText.sanitize_display()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> nil
      line -> cap(line)
    end
  end

  defp cap(line), do: String.slice(line, 0, @max_line)

  defp one_line(text, env, max) do
    text
    |> to_string()
    |> Redact.text(env, max)
    |> LogText.sanitize_display()
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.trim()
  end

  defp schedule_texts(%Run{schedule_ids: []}, _schedules), do: []

  defp schedule_texts(%Run{schedule_ids: ids}, schedules) do
    found = for %{id: id} = schedule <- schedules, id in ids, do: cadence(schedule)
    if found == [], do: ["a schedule that no longer exists"], else: found
  end

  # The Schedules page's own words (`BackupComponents.cadence/1`), in
  # English, as the rest of the email is.
  defp cadence(schedule) do
    Gettext.with_locale(KilnCMSWeb.Gettext, "en", fn ->
      KilnCMSWeb.BackupComponents.cadence(schedule)
    end)
  end

  defp duration(%Run{started_at: %DateTime{} = from, finished_at: %DateTime{} = to}),
    do: max(DateTime.diff(to, from, :second), 0)

  defp duration(_run), do: nil

  defp sizes(artifacts) do
    Enum.reduce(artifacts, %{}, fn artifact, acc ->
      Map.update(acc, text(artifact.kind), artifact.bytes || 0, &(&1 + (artifact.bytes || 0)))
    end)
  end

  defp media_parts(artifacts) do
    for %{kind: :media, parts: parts} <- artifacts, reduce: 0 do
      acc -> acc + length(parts || [])
    end
  end

  defp verified([]), do: nil
  defp verified(artifacts), do: Enum.all?(artifacts, &(&1.verified == true))

  defp text(%UnknownAtom{value: value}), do: value
  defp text(nil), do: ""
  defp text(value), do: to_string(value)

  defp default_org do
    case KilnCMS.Accounts.default_org() do
      %KilnCMS.Accounts.Organization{} = org -> org
      _unreadable -> nil
    end
  end

  defp site_name(org), do: KilnCMS.Branding.for_org(org).site_name

  defp url(path, org), do: ConsoleHost.org_url(path, org)
end
