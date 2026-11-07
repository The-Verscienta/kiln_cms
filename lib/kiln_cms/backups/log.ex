defmodule KilnCMS.Backups.Log do
  @moduledoc """
  The bound on a `KilnCMS.Backups.Run`'s structured log (#2217).

  A log is at most #{200} entries and each message at most #{500} characters,
  redacted. When there are more entries than fit, the first #{50} and the last
  #{149} are kept with one `truncated` marker between them recording how many
  were dropped — the start (what was planned) and the end (what went wrong)
  are the two ends worth keeping. Capping is idempotent, so a writer may cap
  its accumulator at every step boundary.
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
      dropped = count - @head - @tail
      head = Enum.take(entries, @head)
      tail = Enum.take(entries, -@tail)
      at = tail |> List.first() |> Map.get(:at)

      head ++
        [%LogEntry{at: at, level: :warn, step: "truncated", message: marker(dropped)}] ++ tail
    end
  end

  def cap(_other), do: []

  defp marker(dropped), do: "#{dropped} log entries were dropped to bound the log"

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
