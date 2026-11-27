defmodule KilnCMS.Backups.Log do
  @moduledoc """
  The bound on a `KilnCMS.Backups.Run`'s structured log (#2217).

  A log is at most #{200} entries and each message at most #{500} characters,
  redacted. When there are more entries than fit, the first #{50} and the last
  #{149} are kept with one `truncated` marker between them recording how many
  were dropped — the start (what was planned) and the end (what went wrong)
  are the two ends worth keeping. Capping is idempotent, so a writer may cap
  its accumulator at every step boundary. A log capped again after it grew
  (a resume or a re-send appends to it) drops its old marker with the lines
  around it, and the new marker adds the old one's count in, so the count is
  always every entry the run's log has lost.
  """
  alias KilnCMS.Backups.{LogEntry, Redact}

  @max_entries 200
  @max_message 500
  @head 50
  @tail @max_entries - @head - 1

  @doc "The most entries a log keeps, marker included."
  def max_entries, do: @max_entries

  @doc "Redact, truncate and bound a list of entries (structs or maps)."
  @spec cap([LogEntry.t() | map()]) :: [LogEntry.t()]
  def cap(entries) when is_list(entries) do
    entries = Enum.map(entries, &sanitize/1)
    count = length(entries)

    if count <= @max_entries do
      entries
    else
      head = Enum.take(entries, @head)
      tail = Enum.take(entries, -@tail)
      dropped = entries |> Enum.slice(@head, count - @head - @tail) |> dropped_count()
      at = tail |> List.first() |> Map.get(:at)

      head ++
        [%LogEntry{at: at, level: :warn, step: "truncated", message: marker(dropped)}] ++ tail
    end
  end

  def cap(_other), do: []

  # An earlier cap's marker stands for the entries it counted, not for one.
  defp dropped_count(entries),
    do: Enum.reduce(entries, 0, &((marker_count(&1) || 1) + &2))

  defp marker(dropped), do: "#{dropped} log entries were dropped to bound the log"

  @doc """
  Whether `entry` is the marker `cap/1` writes where it dropped entries: the
  `truncated` step, at `:warn`, with exactly the marker's message. A line
  that only calls its step `truncated` (an imported log's, say) is not.
  """
  @spec marker?(LogEntry.t() | map()) :: boolean()
  def marker?(entry), do: marker_count(entry) != nil

  @doc """
  How many entries the marker `cap/1` wrote says were dropped, or `nil` when
  `entry` is not that marker (`marker?/1`). The count is read from the
  marker's own message, which `cap/1` alone writes.
  """
  @spec marker_count(LogEntry.t() | map()) :: non_neg_integer() | nil
  def marker_count(%{step: "truncated", level: :warn, message: message})
      when is_binary(message) do
    case Regex.run(~r/\A(\d+) log entries were dropped to bound the log\z/, message,
           capture: :all_but_first
         ) do
      [count] -> String.to_integer(count)
      nil -> nil
    end
  end

  def marker_count(_entry), do: nil

  defp sanitize(%LogEntry{} = entry) do
    %{entry | message: Redact.text(entry.message, [], @max_message)}
  end

  defp sanitize(%{} = map) do
    %LogEntry{
      at: field(map, :at) || DateTime.utc_now(),
      level: field(map, :level) || :info,
      step: map |> field(:step) |> to_string() |> String.slice(0, 64),
      message: map |> field(:message) |> to_string() |> Redact.text([], @max_message)
    }
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
