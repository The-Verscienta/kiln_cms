defmodule KilnCMS.Backups.ReportMail do
  @moduledoc """
  The email of a backup report (#2229), built from a
  `KilnCMS.Backups.Report` for one platform admin.

  English, like the platform security alerts (`KilnCMS.Security.AlertMail`)
  and for the same reasons: an account stores no language, and the worker
  has no request. Every value in the HTML body is escaped, and the subject
  is one line: the site name, the schedule and the trigger are text people
  chose, and a newline in a header is a header injection.

  The footer names the preference that sent it (`User.notify_on_backup`) and
  where to change it.
  """
  import Swoosh.Email

  alias KilnCMS.Backups.Report

  @max_subject 200

  @doc "The email for `recipient` (an account with an `email`), on `report`."
  @spec build(map(), Report.t()) :: Swoosh.Email.t()
  def build(recipient, %Report{} = report) do
    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(recipient.email))
    |> subject(subject(report))
    |> html_body(html(report, recipient))
    |> text_body(text(report, recipient))
  end

  @doc "The email's subject: one line, at most #{@max_subject} characters."
  @spec subject(Report.t()) :: String.t()
  def subject(%Report{} = report) do
    "#{lead(report)} on #{report.site_name}: #{Report.what(report)}"
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.slice(0, @max_subject)
  end

  defp lead(%Report{recovered?: true, origin: :imported}), do: "Backup finished after all"
  defp lead(%Report{recovered?: true}), do: "Backup recovered"
  defp lead(%Report{class: :failed}), do: "Backup failed"
  defp lead(%Report{class: :partial}), do: "Backup partly off-site"
  defp lead(%Report{class: :succeeded}), do: "Backup report: succeeded"
  defp lead(%Report{class: :skipped}), do: "Backup skipped"
  defp lead(%Report{class: :canceled}), do: "Backup canceled"

  # -- What happened, in sentences --------------------------------------

  # An Interrupted import re-evaluated as complete: never "resumed".
  defp summary(%Report{recovered?: true, origin: :imported} = report),
    do:
      "The cron backup #{report.stamp}, which was recorded as interrupted, " <>
        "finished after all."

  defp summary(%Report{recovered?: true} = report),
    do:
      "The backup #{report.stamp}, which failed earlier, was resumed and has now " <>
        "succeeded#{if report.class == :partial, do: ", though not every off-site destination was reached", else: ""}."

  defp summary(%Report{class: :failed, origin: :imported} = report),
    do: "The cron backup #{report.stamp} failed."

  # Written here, but nowhere off-site (`Report.classify/1`).
  defp summary(%Report{class: :failed, status: :succeeded} = report),
    do: "The backup #{report.stamp} was written here, but no off-site destination was reached."

  defp summary(%Report{class: :failed, resumed_since?: true} = report),
    do:
      "The backup #{report.stamp} failed. It has been resumed since; " <>
        "a later report says how that ended."

  defp summary(%Report{class: :failed} = report),
    do: "The backup #{report.stamp} failed."

  defp summary(%Report{class: :partial} = report),
    do:
      "The backup #{report.stamp} succeeded, but it #{Report.reached(report)}. " <>
        "It can be re-sent to the ones it missed from the Backups page."

  defp summary(%Report{class: :succeeded} = report),
    do: "The backup #{report.stamp} succeeded."

  defp summary(%Report{class: :skipped} = report),
    do: "The backup #{report.stamp} was skipped: this server couldn't take it."

  defp summary(%Report{class: :canceled} = report),
    do: "The backup #{report.stamp} was canceled by a platform admin."

  # [label, value] rows; a value of nil leaves the row out.
  defp facts(%Report{} = report) do
    [
      {"For", Report.what(report)},
      {"Started", stamp(report.started_at)},
      {"Finished", stamp(report.finished_at)},
      {"Took", duration(report.duration_s)},
      {"Components", components(report.components)},
      {"Size", sizes(report)},
      {"Verified", verified(report.verified)}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
  end

  defp destination_line(destination) do
    files =
      if destination.files_total > 0,
        do: ", #{destination.files_ok} of #{destination.files_total} files",
        else: ""

    permanent = if destination.permanent, do: " (retrying won't fix this)", else: ""
    error = if destination.error, do: ": #{destination.error}", else: ""

    "#{destination.label}: #{destination.status}#{files}#{permanent}#{error}"
  end

  defp footer(recipient) do
    "You get this because you are a platform administrator and your backup emails " <>
      "are set to #{preference(recipient)}. You can change that under Your settings, " <>
      "Email notifications. Failed backups always appear in your notifications."
  end

  defp preference(%{notify_on_backup: :every_run}), do: "every run"
  defp preference(_failures), do: "failures only"

  # -- HTML --------------------------------------------------------------

  defp html(report, recipient) do
    rows =
      Enum.map_join(facts(report), "\n", fn {label, value} ->
        "<tr><th align=\"left\">#{escape(label)}</th><td>#{escape(value)}</td></tr>"
      end)

    """
    <p>#{escape(summary(report))}</p>
    <table>#{rows}</table>
    #{html_list("Destinations", Enum.map(report.destinations, &destination_line/1))}
    #{html_list("Errors", report.errors)}
    #{if report.truncated?, do: "<p>More lines are in the log.</p>", else: ""}
    <p><a href="#{escape(report.run_url)}">Open the backup</a> ·
    <a href="#{escape(report.log_url)}">Read its log</a></p>
    <p>#{escape(footer(recipient))}</p>
    """
  end

  defp html_list(_title, []), do: ""

  defp html_list(title, lines) do
    items = Enum.map_join(lines, "\n", &"<li>#{escape(&1)}</li>")
    "<p>#{escape(title)}:</p>\n<ul>#{items}</ul>"
  end

  # -- Text --------------------------------------------------------------

  defp text(report, recipient) do
    facts = Enum.map(facts(report), fn {label, value} -> "#{label}: #{value}" end)

    ([summary(report), ""] ++
       facts ++
       text_list("Destinations", Enum.map(report.destinations, &destination_line/1)) ++
       text_list("Errors", report.errors) ++
       if(report.truncated?, do: ["", "More lines are in the log."], else: []) ++
       [
         "",
         "Open the backup: #{report.run_url}",
         "Read its log: #{report.log_url}",
         "",
         footer(recipient)
       ])
    |> Enum.join("\n")
  end

  defp text_list(_title, []), do: []
  defp text_list(title, lines), do: ["", title <> ":"] ++ Enum.map(lines, &("- " <> &1))

  # -- Values ------------------------------------------------------------

  defp stamp(nil), do: nil

  defp stamp(%DateTime{} = at),
    do: at |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

  defp duration(nil), do: nil
  defp duration(s) when s < 60, do: "#{s} s"
  defp duration(s) when s < 3600, do: "#{div(s, 60)} min #{rem(s, 60)} s"
  defp duration(s), do: "#{div(s, 3600)} h #{div(rem(s, 3600), 60)} min"

  defp components([]), do: nil
  defp components(components), do: Enum.join(components, ", ")

  defp sizes(%Report{sizes: sizes, media_parts: parts}) when map_size(sizes) > 0 do
    Enum.map_join(Enum.sort(sizes), ", ", fn
      {"media", bytes} when parts > 1 -> "media #{bytes(bytes)} in #{parts} parts"
      {kind, bytes} -> "#{kind} #{bytes(bytes)}"
    end)
  end

  defp sizes(_report), do: nil

  defp bytes(b) when b < 1_024, do: "#{b} B"
  defp bytes(b) when b < 1_048_576, do: "#{Float.round(b / 1_024, 1)} KB"
  defp bytes(b) when b < 1_073_741_824, do: "#{Float.round(b / 1_048_576, 1)} MB"
  defp bytes(b), do: "#{Float.round(b / 1_073_741_824, 2)} GB"

  defp verified(nil), do: nil
  defp verified(true), do: "yes"
  defp verified(false), do: "not every file"

  defp escape(text),
    do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
