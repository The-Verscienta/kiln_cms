defmodule KilnCMS.Backups.Artifact.ValidateDestinations do
  @moduledoc """
  An artifact's `destinations` map must be `%{"local" | "rclone:<remote>" =>
  %{"status" => "pending" | "ok" | "failed" | "pruned", ...}}` (#2217).
  """
  use Ash.Resource.Validation

  @statuses ~w(pending ok failed pruned)

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
  defp valid?(_other), do: false
end
