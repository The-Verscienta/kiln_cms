defmodule KilnCMS.Backups.Refused do
  @moduledoc """
  A backup request the pipeline refused (#2218), carrying the reason as a term:
  `availability/0`'s reason, a resume refusal (`Backups.resumable_run/2`),
  `:in_flight` or `{:queue_busy, queued}`. `KilnCMS.Backups.request/2` unwraps it back to
  `{:error, reason}`.
  """
  use Splode.Error, fields: [:reason], class: :invalid

  @impl true
  def message(%{reason: reason}), do: "backup request refused: #{inspect(reason)}"
end
