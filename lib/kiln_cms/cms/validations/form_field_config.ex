defmodule KilnCMS.CMS.Validations.FormFieldConfig do
  @moduledoc """
  The per-type configuration rules of a `KilnCMS.CMS.FormField` (#2261):

    * `:select`, `:radio` and `:checkboxes` list at least one option; options
      are non-blank, unique and at most `KilnCMS.Limits.line/0` long, and a
      `:checkboxes` field has at most 50 of them;
    * `min_value`/`max_value`/`step` belong to `:number` (all three) and
      `:rating` (`max_value` only) and are `nil` on every other type; for a
      number `min_value <= max_value` and `step > 0`; a rating's `max_value`
      is a whole number from 1 to 10;
    * a `:hidden` field is never `required` (the visitor never sees it, and
      its value is whatever the client sends).

  The honeypot-name rule is `KilnCMS.CMS.Validations.ReservedFieldName`'s
  (#2267), for every type.

  Kept apart from `KilnCMS.CMS.Validations.SelectOptions`, which
  `FieldDefinition` reuses with its own `allow_custom` semantics.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidAttribute

  @choice_types [:select, :radio, :checkboxes]
  @max_checkbox_options 50
  @max_rating 10

  @doc "The most options a `:checkboxes` field may list."
  @spec max_checkbox_options() :: pos_integer()
  def max_checkbox_options, do: @max_checkbox_options

  @doc "The most stars a `:rating` field may have."
  @spec max_rating() :: pos_integer()
  def max_rating, do: @max_rating

  @impl true
  def validate(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)

    attrs = %{
      type: type,
      options: Ash.Changeset.get_attribute(changeset, :options) || [],
      required: Ash.Changeset.get_attribute(changeset, :required),
      min: Ash.Changeset.get_attribute(changeset, :min_value),
      max: Ash.Changeset.get_attribute(changeset, :max_value),
      step: Ash.Changeset.get_attribute(changeset, :step)
    }

    Enum.find_value(
      [&options/1, &range/1, &hidden/1],
      :ok,
      fn check ->
        case check.(attrs) do
          :ok -> nil
          error -> error
        end
      end
    )
  end

  defp error(field, message),
    do: {:error, InvalidAttribute.exception(field: field, message: message)}

  # --- options ----------------------------------------------------------------

  defp options(%{type: type, options: []}) when type in @choice_types do
    error(:options, choice_message(type))
  end

  defp options(%{type: type, options: options}) when type in @choice_types do
    cond do
      Enum.any?(options, &(String.trim(&1) == "")) ->
        error(:options, gettext("options can't be blank"))

      Enum.any?(options, &(String.length(&1) > KilnCMS.Limits.line())) ->
        error(
          :options,
          gettext("each option must be at most %{max} characters", max: KilnCMS.Limits.line())
        )

      length(Enum.uniq(options)) != length(options) ->
        error(:options, gettext("options must be unique"))

      type == :checkboxes and length(options) > @max_checkbox_options ->
        error(
          :options,
          gettext("a checkboxes field can have at most %{max} options",
            max: @max_checkbox_options
          )
        )

      true ->
        :ok
    end
  end

  defp options(_attrs), do: :ok

  defp choice_message(:select), do: gettext("a select field must list at least one option")
  defp choice_message(:radio), do: gettext("a radio field must list at least one option")

  defp choice_message(:checkboxes),
    do: gettext("a checkboxes field must list at least one option")

  # --- range ------------------------------------------------------------------

  defp range(%{type: :number, min: min, max: max, step: step}) do
    cond do
      is_number(min) and is_number(max) and min > max ->
        error(:min_value, gettext("can't be more than the maximum (%{max})", max: max))

      is_number(step) and step <= 0 ->
        error(:step, gettext("must be greater than zero"))

      true ->
        :ok
    end
  end

  defp range(%{type: :rating, min: nil, step: nil, max: max}) do
    if is_nil(max) or (max == trunc(max) and max >= 1 and max <= @max_rating),
      do: :ok,
      else:
        error(:max_value, gettext("must be a whole number from 1 to %{max}", max: @max_rating))
  end

  defp range(%{type: :rating}) do
    error(:max_value, gettext("a rating only has a star count"))
  end

  defp range(%{min: nil, max: nil, step: nil}), do: :ok

  defp range(_attrs) do
    error(:min_value, gettext("only a number or rating field takes a range"))
  end

  # --- hidden -------------------------------------------------------------------

  defp hidden(%{type: :hidden, required: true}),
    do: error(:required, gettext("a hidden field can't be required"))

  defp hidden(_attrs), do: :ok
end
