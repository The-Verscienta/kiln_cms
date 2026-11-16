defmodule KilnCMS.Backups.Artifact.ValidateDestinations do
  @moduledoc """
  An artifact's `destinations` map must be `%{"local" | "rclone:<remote>" |
  "dest:<uuid>" => %{"status" => "pending" | "ok" | "failed" | "pruned", ...}}`
  (#2217, #2220).

  `dest:` takes a canonical lowercase UUID only (a stored
  `KilnCMS.Backups.DestinationConfig`'s id, as `KilnCMS.Backups.Destination`
  builds the key), so one destination never has two keys. Any other key is
  refused.
  """
  use Ash.Resource.Validation

  @statuses ~w(pending ok failed pruned)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :destinations) do
      nil -> :ok
      destinations -> check(destinations)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)

  defp check(destinations) when is_map(destinations) do
    if Enum.all?(destinations, &valid?/1),
      do: :ok,
      else: {:error, field: :destinations, message: "has an unknown destination or status"}
  end

  defp check(_other), do: {:error, field: :destinations, message: "must be a map"}

  defp valid?({"local", %{"status" => status}}), do: status in @statuses
  defp valid?({"rclone:" <> _remote, %{"status" => status}}), do: status in @statuses

  defp valid?({"dest:" <> id, %{"status" => status}}),
    do: status in @statuses and Regex.match?(@uuid, id)

  defp valid?(_other), do: false
end
