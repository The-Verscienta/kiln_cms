defmodule KilnCMS.CMS.Validations.FieldRules do
  @moduledoc """
  Sanity-checks a `FormField.validation` rule map at write time so the
  submission pipeline (`KilnCMS.Forms`) can trust what it reads: only known
  keys, non-negative numeric bounds, a `pattern` that actually compiles.
  Catching a broken regex here beats silently skipping it per submission.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @known_keys ~w(min_length max_length min max pattern message)

  @impl true
  def validate(changeset, _opts, _context) do
    rules = Ash.Changeset.get_attribute(changeset, :validation) || %{}

    Enum.find_value(rules, :ok, fn {key, value} ->
      case check(key, value) do
        :ok ->
          nil

        {:error, message} ->
          {:error, InvalidAttribute.exception(field: :validation, message: message)}
      end
    end)
  end

  defp check(key, _value) when key not in @known_keys,
    do: {:error, "unknown rule #{inspect(key)} (allowed: #{Enum.join(@known_keys, ", ")})"}

  defp check(key, value) when key in ~w(min_length max_length) do
    if is_integer(value) and value >= 0,
      do: :ok,
      else: {:error, "#{key} must be a non-negative whole number"}
  end

  defp check(key, value) when key in ~w(min max) do
    if is_number(value), do: :ok, else: {:error, "#{key} must be a number"}
  end

  defp check("pattern", value) do
    with true <- is_binary(value),
         {:ok, _regex} <- Regex.compile(value) do
      :ok
    else
      _invalid -> {:error, "pattern must be a valid regular expression"}
    end
  end

  defp check("message", value) do
    if is_binary(value), do: :ok, else: {:error, "message must be text"}
  end
end
