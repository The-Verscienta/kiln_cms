defmodule KilnCMS.Backups.DestinationConfig.Fields do
  @moduledoc """
  An adapter's form fields (`c:Kiln.BackupDestination.fields/0`), read once
  for a `KilnCMS.Backups.DestinationConfig` write: which are secret, which
  are required, and what type a setting must have.

  `fields/0` is plugin code. One that raises, or answers something that is
  not a list of fields, is `{:error, message}`, so a broken plugin refuses
  the form rather than crashing the request. Entries without a string `name`
  or a known `type` are left out, and a `help` that is not text is none.
  """

  @types [:string, :boolean, :integer, :secret]

  @typedoc "A field as `Kiln.BackupDestination` declares it."
  @type field :: %{
          name: String.t(),
          type: atom(),
          required?: boolean(),
          help: String.t() | nil
        }

  @doc "`module`'s fields, or `{:error, message}`."
  @spec of(module()) :: {:ok, [field()]} | {:error, String.t()}
  def of(module) do
    case safely(module) do
      fields when is_list(fields) -> {:ok, Enum.flat_map(fields, &field/1)}
      _other -> {:error, "#{inspect(module)}.fields/0 did not return a list of fields"}
    end
  end

  @doc "The `:secret` fields' names."
  @spec secret_names([field()]) :: [String.t()]
  def secret_names(fields), do: for(%{type: :secret, name: name} <- fields, do: name)

  @doc "The non-secret fields."
  @spec settings([field()]) :: [field()]
  def settings(fields), do: Enum.reject(fields, &(&1.type == :secret))

  # Raising plugin code is that plugin's error, not the request's: rescued
  # here, where the form is told the adapter is broken.
  defp safely(module) do
    module.fields()
  rescue
    _error -> :raised
  end

  defp field(%{name: name, type: type} = field) when is_binary(name) and type in @types do
    help = Map.get(field, :help)

    [
      %{
        name: name,
        type: type,
        required?: Map.get(field, :required?) == true,
        help: if(is_binary(help) and help != "", do: help)
      }
    ]
  end

  defp field(_other), do: []
end
