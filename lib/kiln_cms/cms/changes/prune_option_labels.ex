defmodule KilnCMS.CMS.Changes.PruneOptionLabels do
  @moduledoc """
  Keeps a `FieldDefinition`'s `option_labels` in step with its `options`: a
  label whose option is gone is dropped, a blank label or one that only
  repeats its value is dropped (the value is its own label), each label is
  trimmed, and a field that is not a `:select` keeps none.

  The same stance as `KilnCMS.CMS.Changes.ClearMultiple`: removing an option
  in the fields admin submits no label for it, and a stale label would
  otherwise survive under a value no record may hold. A label longer than a
  line is an error rather than a silent cut, since it is the text an editor
  chooses by.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :field_type) == :select do
      options = Ash.Changeset.get_attribute(changeset, :options) || []
      labels = Ash.Changeset.get_attribute(changeset, :option_labels) || %{}
      pruned = prune(labels, options)
      line = KilnCMS.Limits.line()

      changeset
      |> Ash.Changeset.force_change_attribute(:option_labels, pruned)
      |> check_length(Enum.find(pruned, fn {_value, label} -> String.length(label) > line end))
    else
      Ash.Changeset.force_change_attribute(changeset, :option_labels, %{})
    end
  end

  defp check_length(changeset, nil), do: changeset

  defp check_length(changeset, {value, _label}) do
    Ash.Changeset.add_error(
      changeset,
      InvalidAttribute.exception(
        field: :option_labels,
        message: "the label for %{value} is longer than %{max} characters",
        vars: [value: value, max: KilnCMS.Limits.line()]
      )
    )
  end

  defp prune(labels, options) when is_map(labels) do
    for {value, label} <- labels,
        value = to_string(value),
        value in options,
        is_binary(label),
        label = String.trim(label),
        label not in ["", value],
        into: %{},
        do: {value, label}
  end

  defp prune(_labels, _options), do: %{}
end
