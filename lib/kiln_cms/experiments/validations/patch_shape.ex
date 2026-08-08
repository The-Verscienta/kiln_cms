defmodule KilnCMS.Experiments.Validations.PatchShape do
  @moduledoc """
  Validates a variant's patch (#499).

  The allowlist is the point. A patch that could set `slug` would move the page
  under the visitor; one that could set `state` or `audience` would publish or
  unpaywall a document from what looks like a copy-editing form. So `fields` is
  checked against `KilnCMS.Experiments.Variant.patchable_fields/0` and everything
  else is refused by name rather than ignored — silently dropping a key an editor
  wrote is how someone concludes the experiment did nothing.

  `blocks` keys must be uuids, because they address a block by its stable `_id`.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Experiments.Variant

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :patch) do
      patch when is_map(patch) -> validate_patch(patch)
      nil -> :ok
      _other -> {:error, field: :patch, message: "must be a map"}
    end
  end

  defp validate_patch(patch) do
    with :ok <- validate_keys(patch),
         :ok <- validate_fields(Map.get(patch, "fields", %{})) do
      validate_blocks(Map.get(patch, "blocks", %{}))
    end
  end

  defp validate_keys(patch) do
    case Map.keys(patch) -- ["fields", "blocks"] do
      [] -> :ok
      extra -> {:error, field: :patch, message: "unknown patch key(s): #{Enum.join(extra, ", ")}"}
    end
  end

  defp validate_fields(fields) when is_map(fields) do
    case Map.keys(fields) -- Variant.patchable_fields() do
      [] ->
        :ok

      refused ->
        {:error,
         field: :patch,
         message:
           "these fields may not be varied: #{Enum.join(refused, ", ")}. " <>
             "Patchable: #{Enum.join(Variant.patchable_fields(), ", ")}"}
    end
  end

  defp validate_fields(_fields), do: {:error, field: :patch, message: "`fields` must be a map"}

  defp validate_blocks(blocks) when is_map(blocks) do
    blocks
    |> Map.keys()
    |> Enum.reject(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> case do
      [] ->
        :ok

      bad ->
        {:error, field: :patch, message: "block keys must be block ids: #{Enum.join(bad, ", ")}"}
    end
  end

  defp validate_blocks(_blocks), do: {:error, field: :patch, message: "`blocks` must be a map"}
end
