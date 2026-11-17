defmodule KilnCMS.Backups.Run.Changes.ResumeNote do
  @moduledoc """
  The note a resume that never re-opened its run leaves on that run, shared by
  `Run.Changes.ResumeRefused` (#2539: the resume couldn't run) and
  `Run.Changes.CancelResume` (#2816: a platform admin canceled it before it
  started).

  The error becomes the note, then the previous error on the next line, and
  the log gains the note. A previous error whose first line is already such a
  note (`"Resume refused: ..."`, `"Resume canceled ..."`) loses that line, so
  notes never stack and the original failure is kept.
  """

  @notes ["Resume refused: ", "Resume canceled "]
  @interrupted "Interrupted: the job was killed or the node stopped"

  @doc """
  The previous-error line of a stale `running` run that a note fails: the
  stale-run sweep's own line.
  """
  @spec interrupted() :: String.t()
  def interrupted, do: @interrupted

  @doc "Set the run's error to `message` over `previous`, and log `message` at `level`."
  @spec put(Ash.Changeset.t(), String.t(), :info | :warn | :error, String.t() | nil, DateTime.t()) ::
          Ash.Changeset.t()
  def put(changeset, message, level, previous, now) do
    entry = %{at: now, level: level, step: "resume", message: message}

    changeset
    |> Ash.Changeset.force_change_attribute(:error, error(message, previous))
    |> Ash.Changeset.force_change_attribute(:log, (changeset.data.log || []) ++ [entry])
  end

  defp error(message, nil), do: message

  defp error(message, previous) do
    previous =
      if Enum.any?(@notes, &String.starts_with?(previous, &1)) do
        previous |> String.split("\n", parts: 2) |> Enum.at(1)
      else
        previous
      end

    case previous do
      blank when blank in [nil, ""] -> message
      previous -> message <> "\n" <> previous
    end
  end
end
