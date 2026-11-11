defmodule KilnCMS.CMS.Validations.FieldConstraints do
  @moduledoc """
  Keeps a `FieldDefinition`'s `validation` map (#2276) to constraints that
  mean something: known keys of the right shape, applicable to the field's
  type, satisfiable, and safe to run.

    * keys are `min`, `max`, `min_length`, `max_length`, `pattern`,
      `pattern_message` and `unique` — anything else is refused;
    * `min`/`max` for `:integer`/`:float` (an integer field takes integer
      bounds); `min_length`/`max_length`/`pattern`/`pattern_message` for
      `:string`, `:url` and plain `:text`; `unique` for single-valued
      `:string`, `:url`, `:integer`, `:float`, `:date`, `:datetime` and `:slug`
      top-level fields — not on a computed, shared-localization, link or
      group sub-field, and not alongside a `default`;
    * on a `multiple` field (a list of phrases, numbers, links, …) every
      constraint but `unique` applies to each item;
    * `min <= max`, `min_length <= max_length`;
    * the `pattern` is at most `KilnCMS.Limits.pattern/0` characters and
      compiles;
    * the field's `default` satisfies the constraints it would otherwise
      store unchecked.

  A type change leaves stale keys behind, so they are refused here rather
  than silently dropped; the fields admin clears them client side.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.CMS.FieldConstraints

  @impl true
  def validate(changeset, _opts, _context) do
    validation = Ash.Changeset.get_attribute(changeset, :validation)

    cond do
      validation in [nil, %{}] ->
        :ok

      not is_map(validation) ->
        error("must be an object of constraints")

      true ->
        validation = FieldConstraints.normalize(validation)

        with :ok <- keys(validation),
             :ok <- shapes(validation),
             :ok <- applicable(changeset, validation),
             :ok <- ordered(validation),
             :ok <- pattern(validation),
             :ok <- unique(changeset, validation) do
          default(changeset, validation)
        end
    end
  end

  defp keys(validation) do
    case Enum.reject(Map.keys(validation), &(&1 in FieldConstraints.keys())) do
      [] ->
        :ok

      unknown ->
        error("has unknown constraints: %{keys}", keys: unknown |> Enum.sort() |> Enum.join(", "))
    end
  end

  defp shapes(validation) do
    Enum.find_value(validation, :ok, fn {key, value} ->
      if shape_ok?(key, value), do: nil, else: error("#{key} is not valid: #{shape_hint(key)}")
    end)
  end

  defp shape_ok?(key, value) when key in ["min", "max"], do: is_number(value)

  defp shape_ok?(key, value) when key in ["min_length", "max_length"],
    do: is_integer(value) and value >= 0

  defp shape_ok?("pattern", value), do: is_binary(value) and value != ""
  defp shape_ok?("pattern_message", value), do: is_binary(value)
  defp shape_ok?("unique", value), do: is_boolean(value)

  defp shape_hint(key) when key in ["min", "max"], do: "expected a number"

  defp shape_hint(key) when key in ["min_length", "max_length"],
    do: "expected a whole number of 0 or more"

  defp shape_hint("pattern"), do: "expected a non-empty pattern"
  defp shape_hint("pattern_message"), do: "expected text"
  defp shape_hint("unique"), do: "expected true or false"

  defp applicable(changeset, validation) do
    type = Ash.Changeset.get_attribute(changeset, :field_type)
    format = Ash.Changeset.get_attribute(changeset, :format)
    allowed = FieldConstraints.allowed_keys(type, format)

    case validation |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] ->
        integer_bounds(type, validation)

      stray ->
        error("%{keys} can't be set on a %{type} field",
          keys: Enum.join(stray, ", "),
          type: type
        )
    end
  end

  defp integer_bounds(:integer, validation) do
    if Enum.all?(["min", "max"], &(is_nil(validation[&1]) or is_integer(validation[&1]))),
      do: :ok,
      else: error("min and max must be whole numbers on an integer field")
  end

  defp integer_bounds(_type, _validation), do: :ok

  defp ordered(validation) do
    cond do
      inverted?(validation["min"], validation["max"]) ->
        error("min can't be more than max")

      inverted?(validation["min_length"], validation["max_length"]) ->
        error("min_length can't be more than max_length")

      true ->
        :ok
    end
  end

  defp inverted?(low, high), do: is_number(low) and is_number(high) and low > high

  defp pattern(%{"pattern" => pattern} = validation) do
    message = validation["pattern_message"]

    cond do
      String.length(pattern) > KilnCMS.Limits.pattern() ->
        error("pattern can be at most %{max} characters", max: KilnCMS.Limits.pattern())

      is_binary(message) and String.length(message) > KilnCMS.Limits.pattern() ->
        error("pattern_message can be at most %{max} characters", max: KilnCMS.Limits.pattern())

      true ->
        case FieldConstraints.compile(pattern) do
          {:ok, _regex} ->
            :ok

          {:error, reason} ->
            error("pattern is not a valid regular expression: %{reason}", reason: reason)
        end
    end
  end

  defp pattern(_validation), do: :ok

  defp unique(changeset, %{"unique" => true}) do
    cond do
      nested?(changeset) ->
        error("unique can't be set on a field inside a relationship or group")

      Ash.Changeset.get_attribute(changeset, :multiple) == true ->
        error("unique can't be set on a field that holds several values")

      Ash.Changeset.get_attribute(changeset, :localization) == :shared ->
        error("unique can't be set on a field shared between locales")

      not is_nil(Ash.Changeset.get_attribute(changeset, :default)) and
          Ash.Changeset.get_attribute(changeset, :default) != "" ->
        error("unique can't be set on a field with a default value")

      true ->
        :ok
    end
  end

  defp unique(_changeset, _validation), do: :ok

  defp nested?(changeset) do
    not is_nil(Ash.Changeset.get_attribute(changeset, :link_of_id)) or
      not is_nil(Ash.Changeset.get_attribute(changeset, :group_of_id))
  end

  # The default is stored unchecked when a field is left blank, so it has to
  # satisfy what everything else must.
  defp default(changeset, validation) do
    default = Ash.Changeset.get_attribute(changeset, :default)

    if is_binary(default) and String.trim(default) != "" do
      definition = %{
        name: "default",
        label: "default",
        field_type: Ash.Changeset.get_attribute(changeset, :field_type),
        format: Ash.Changeset.get_attribute(changeset, :format),
        multiple: false,
        validation: validation
      }

      case FieldConstraints.check_default(definition, default) do
        [] -> :ok
        [{_path, _label, message} | _] -> error("default value %{message}", message: message)
      end
    else
      :ok
    end
  end

  # Vars are interpolated here: Ash inspects `vars`, which would quote them.
  defp error(message, vars \\ []) do
    message =
      Enum.reduce(vars, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)

    {:error, InvalidAttribute.exception(field: :validation, message: message)}
  end
end
