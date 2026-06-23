defmodule KilnCMS.Search.Vector do
  @moduledoc """
  Ash type for a pgvector `vector(N)` column holding a fixed-length list of
  floats. `N` is the configured embedding dimension
  (`config :kiln_cms, KilnCMS.Search, dim: ...`), read at compile time so the
  column type and the model stay in lock-step.

  Internally the value is a plain list of floats; on the wire it round-trips
  through `Pgvector` structs, which the registered Postgrex extension
  (`KilnCMS.PostgrexTypes`) encodes/decodes.
  """
  use Ash.Type

  @dimensions Application.compile_env(:kiln_cms, [KilnCMS.Search, :dim], 384)

  @doc "Configured embedding dimension this type stores."
  def dimensions, do: @dimensions

  @impl true
  def storage_type(_constraints), do: :"vector(#{@dimensions})"

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(value, _constraints) when is_list(value), do: {:ok, value}
  def cast_input(%Pgvector{} = vector, _constraints), do: {:ok, Pgvector.to_list(vector)}
  def cast_input(_other, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(%Pgvector{} = vector, _constraints), do: {:ok, Pgvector.to_list(vector)}
  def cast_stored(value, _constraints) when is_list(value), do: {:ok, value}
  def cast_stored(_other, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints) when is_list(value), do: {:ok, Pgvector.new(value)}
  def dump_to_native(%Pgvector{} = vector, _constraints), do: {:ok, vector}
  def dump_to_native(_other, _constraints), do: :error
end
