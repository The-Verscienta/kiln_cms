defmodule KilnCMS.Backups.DestinationConfig.Changes.Normalize do
  @moduledoc """
  What a `KilnCMS.Backups.DestinationConfig` create or update stores (#2220):
  the name trimmed, and `settings` keyed by string with blank values dropped,
  strings trimmed, and form text cast to the type the adapter declares for
  the field (`"true"` for a `:boolean`, `"30"` for an `:integer`).

  A value that does not cast is left as it came, for
  `Validations.AdapterSettings` to refuse with the field's name. Keys the
  adapter doesn't declare are kept too, so that validation can refuse them
  rather than have them vanish.
  """
  use Ash.Resource.Change

  alias KilnCMS.Backups.Destination
  alias KilnCMS.Backups.DestinationConfig.Fields

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> normalize(:name, &trim/1)
    |> normalize(:settings, &settings(&1, types(changeset)))
  end

  defp normalize(changeset, field, fun) do
    case Ash.Changeset.fetch_change(changeset, field) do
      {:ok, nil} -> changeset
      {:ok, value} -> Ash.Changeset.force_change_attribute(changeset, field, fun.(value))
      :error -> changeset
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  # `%{name => type}` of the adapter's fields; empty when it is not installed
  # (the validation refuses that).
  defp types(changeset) do
    with kind when is_binary(kind) <- Ash.Changeset.get_attribute(changeset, :kind),
         {:ok, module} <- Destination.adapter(kind),
         {:ok, fields} <- Fields.of(module) do
      Map.new(fields, &{&1.name, &1.type})
    else
      _ -> %{}
    end
  end

  defp settings(settings, types) when is_map(settings) do
    for {name, value} <- settings,
        name = to_string(name),
        value = value |> trim() |> cast(Map.get(types, name)),
        value not in [nil, ""],
        into: %{},
        do: {name, value}
  end

  defp settings(other, _types), do: other

  defp cast(value, :boolean) when value in ["true", "on", "1"], do: true
  defp cast(value, :boolean) when value in ["false", "off", "0"], do: false

  defp cast(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp cast(value, _type), do: value
end
