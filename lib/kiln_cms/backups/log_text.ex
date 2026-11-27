defmodule KilnCMS.Backups.LogText do
  @moduledoc """
  A backup run's log as people read it (part of #2230): the Log tab
  (`KilnCMSWeb.BackupLogLive`) and the log download
  (`KilnCMSWeb.BackupLogController`) both take it from here, so the page and
  the file say the same thing.

  ## Redacted again when read

  `KilnCMS.Backups.Log.cap/1` redacts each line when it is stored, but only
  with the secrets this process knew then. Each message, and the run's
  `error`, goes through `KilnCMS.Backups.Redact.text/3` again here, with the
  database password of `KilnCMS.Backups.pg_connection/1` as a known secret
  (`read_env/0`) besides the process's own secret variables. So a secret set
  or rotated after the line was written, or a pattern a later release adds to
  `Redact`, applies to old rows too.

  The limit: a secret is removed literally only when this process knows it
  now. A destination's credentials are removed by `Redact`'s patterns (URL
  userinfo, `key=value`), not by value, and a password the database URL no
  longer carries is not known at all.

  ## Characters a terminal would act on

  `sanitize_display/1` replaces with U+FFFD every C0 control character but
  tab and newline (ESC above all: rclone or pg_dump stderr may carry terminal
  escape sequences, and someone will `cat` the download), DEL, the C1 controls
  (U+0080 to U+009F) and the bidirectional overrides and isolates (U+202A to
  U+202E, U+2066 to U+2069), which can make a line read as something it isn't.
  A `\\r\\n` line ending becomes `\\n` first.

  ## Levels

  `entries/3` filters by a minimum level: `:all`, `:warn` (warnings and
  errors) or `:error`. The `truncated` marker `Log.cap/1` writes is kept at
  every level, so a filtered view never hides that lines were dropped.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Log, LogEntry, Redact, Run}

  @filters [:all, :warn, :error]
  @max_message 500
  @max_error 4_000
  @max_step 64
  @max_trigger 64

  # C0 but tab and newline, DEL, C1, and the bidi overrides and isolates.
  @unsafe ~r/[\x{0000}-\x{0008}\x{000B}-\x{001F}\x{007F}-\x{009F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @doc "The level filters, in the order they are offered."
  @spec filters() :: [:all | :warn | :error]
  def filters, do: @filters

  @doc """
  The secrets to remove literally when a log is read: the `PGPASSWORD`
  `KilnCMS.Backups.pg_connection/1` would give pg_dump (its TLS settings are
  not secrets, and `Redact` leaves them alone by name). `[]` when there is no
  database URL, or one `pg_connection/1` refuses.
  """
  @spec read_env() :: [{String.t(), String.t()}]
  def read_env do
    case Backups.pg_connection() do
      {:ok, {_url, env}} -> env
      {:error, _refusal} -> []
    end
  end

  @doc """
  The run's log entries at or above `filter` (`filters/0`), each step and
  message redacted again with `env` and sanitized (a step is one line, at
  most #{@max_step} characters). The `truncated` marker is kept at every
  level.
  """
  @spec entries(Run.t() | [LogEntry.t()], :all | :warn | :error, [{String.t(), String.t()}]) ::
          [LogEntry.t()]
  def entries(run_or_log, filter, env \\ read_env())

  def entries(%Run{log: log}, filter, env), do: entries(log, filter, env)

  def entries(log, filter, env) when is_list(log) and filter in @filters do
    for entry <- log, shown?(entry, filter) do
      %{
        entry
        | step: entry.step |> Redact.text(env, @max_step) |> sanitize_display() |> one_line(),
          message: message(entry, env)
      }
    end
  end

  @doc "How many entries each filter shows, the `truncated` marker included in each."
  @spec counts(Run.t() | [LogEntry.t()]) :: %{all: integer(), warn: integer(), error: integer()}
  def counts(%Run{log: log}), do: counts(log)

  def counts(log) when is_list(log),
    do: Map.new(@filters, fn filter -> {filter, Enum.count(log, &shown?(&1, filter))} end)

  @doc """
  Whether `entry` is the marker `KilnCMS.Backups.Log.cap/1` writes where it
  dropped lines (`KilnCMS.Backups.Log.marker?/1`), not just any line whose
  step is called `truncated`.
  """
  @spec truncated?(LogEntry.t()) :: boolean()
  def truncated?(entry), do: Log.marker?(entry)

  @doc """
  A run's trigger as shown: operator-supplied text (`BACKUP_TRIGGER`, a cron
  manifest's), so redacted again with `env`, sanitized, one line and at most
  #{@max_trigger} characters.
  """
  @spec trigger(term(), [{String.t(), String.t()}]) :: String.t()
  def trigger(trigger, env \\ read_env()),
    do:
      trigger |> to_string() |> Redact.text(env, @max_trigger) |> sanitize_display() |> one_line()

  @doc "The run's `error`, redacted again with `env` and sanitized; nil when it has none."
  @spec error(Run.t(), [{String.t(), String.t()}]) :: String.t() | nil
  def error(run, env \\ read_env())
  def error(%Run{error: nil}, _env), do: nil

  def error(%Run{error: error}, env),
    do: error |> Redact.text(env, @max_error) |> sanitize_display()

  @doc """
  `text` with the characters a terminal or a bidi renderer would act on
  replaced by U+FFFD (see the moduledoc). A non-binary is `""`.
  """
  @spec sanitize_display(term()) :: String.t()
  def sanitize_display(text) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> String.replace("\r\n", "\n")
    |> String.replace(@unsafe, "\u{FFFD}")
  end

  def sanitize_display(_other), do: ""

  @doc """
  The download's body: a few `#` header lines about the run, a blank line,
  then one line per entry (`<ISO 8601> <LEVEL> <step> <message>`), every
  level, with a multi-line message's further lines indented by two spaces.
  Redacted again and sanitized throughout. English, as the log itself is.
  """
  @spec render_text(Run.t(), [{String.t(), String.t()}]) :: String.t()
  def render_text(%Run{} = run, env \\ read_env()) do
    header =
      [
        "# Kiln backup log",
        "# Backup: #{run.stamp} (#{trigger(run.trigger, env)}, #{run.status})",
        "# Started: #{iso(run.started_at)}",
        "# Finished: #{iso(run.finished_at)}",
        "# Components: #{components(run.components)}",
        "# Origin: #{run.origin}"
      ] ++ error_lines(error(run, env))

    lines = Enum.map(entries(run, :all, env), &entry_line/1)

    Enum.join(header ++ [""] ++ lines, "\n") <> "\n"
  end

  defp shown?(_entry, :all), do: true
  defp shown?(entry, filter), do: Log.marker?(entry) or level_shown?(entry.level, filter)

  defp level_shown?(level, :warn), do: level in [:warn, :error]
  defp level_shown?(level, :error), do: level == :error

  defp message(%{message: message}, env),
    do: message |> Redact.text(env, @max_message) |> sanitize_display()

  defp entry_line(entry) do
    level = entry.level |> to_string() |> String.upcase() |> String.pad_trailing(5)
    "#{iso(entry.at)} #{level} #{entry.step} #{indent(entry.message, "  ")}"
  end

  defp error_lines(nil), do: []
  defp error_lines(error), do: ["# Error: " <> indent(error, "#   ")]

  defp indent(text, prefix), do: String.replace(text, "\n", "\n" <> prefix)

  defp one_line(text), do: String.replace(text, "\n", " ")

  defp components([]), do: "-"
  defp components(components), do: Enum.map_join(components, ", ", &component/1)

  defp component(%KilnCMS.Types.UnknownAtom{value: value}), do: value
  defp component(component), do: to_string(component)

  defp iso(nil), do: "-"
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
