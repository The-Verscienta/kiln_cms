defmodule Kiln.Block.Sample do
  @moduledoc """
  Builds a `Kiln.Block` struct populated with representative field values, for
  exercising a block's `:json` render against its exported schema (#937).

  Shared by `test/kiln/block/json_schema_test.exs` (the core conformance
  suite) and `mix kiln.plugins.doctor` (the same check run against
  plugin-contributed blocks), so the two sample builders cannot drift apart
  the way two independent copies eventually would.
  """

  alias Kiln.Block.Info

  @doc """
  A block with every declared field carrying a value of its declared type —
  the populated branch of `render/2`.

  `date`/`datetime` default to "now", which is what a live `mix
  kiln.plugins.doctor` run wants; the test suite passes fixed values instead
  so its assertions stay deterministic across runs.
  """
  @spec populated(module(), Date.t(), DateTime.t()) :: struct()
  def populated(module, date \\ Date.utc_today(), datetime \\ DateTime.utc_now()) do
    module
    |> Info.fields()
    |> Enum.reduce(struct(module, id: Ecto.UUID.generate()), fn field, block ->
      Map.put(block, field.name, sample(field.type, date, datetime))
    end)
  end

  @doc """
  A block with only its `required: true` fields carrying a value — the
  emptiest a block can legitimately be post-#935: the write path (top-level or
  nested) no longer stores one with a required field omitted, so a bare
  `struct(module)` (every field `nil`) is a state `:json` render never has to
  handle for a block with a required field, and checking it there produces a
  false positive rather than a real gap. This is the render-conformance
  counterpart to `populated/3`'s populated branch — some blocks (e.g.
  `KilnCMS.Blocks.Video`) take a different `:json` path depending on which
  *optional* fields are present, which is what this exercises for them.
  """
  @spec required_only(module(), Date.t(), DateTime.t()) :: struct()
  def required_only(module, date \\ Date.utc_today(), datetime \\ DateTime.utc_now()) do
    module
    |> Info.fields()
    |> Enum.filter(& &1.required)
    |> Enum.reduce(struct(module, id: Ecto.UUID.generate()), fn field, block ->
      Map.put(block, field.name, sample(field.type, date, datetime))
    end)
  end

  @doc """
  The representative value `populated/3` would put in one field of the given
  type. Exposed so a caller building a *partial* sample (e.g. `required_only/3`,
  or a string-keyed attrs map rather than a struct) doesn't need its own copy
  of this per-type mapping.
  """
  @spec sample_value(term(), Date.t(), DateTime.t()) :: term()
  def sample_value(type, date \\ Date.utc_today(), datetime \\ DateTime.utc_now()),
    do: sample(type, date, datetime)

  defp sample(:integer, _date, _datetime), do: 3
  defp sample(:float, _date, _datetime), do: 1.5
  defp sample(:boolean, _date, _datetime), do: true
  defp sample(:date, date, _datetime), do: date
  defp sample(:datetime, _date, datetime), do: datetime
  defp sample(:url, _date, _datetime), do: "https://example.com/a"
  defp sample(:email, _date, _datetime), do: "editor@example.com"
  defp sample(:color, _date, _datetime), do: "#112233"
  defp sample(:rich_text, _date, _datetime), do: [%{"_type" => "block", "children" => []}]
  defp sample({:array, :map}, _date, _datetime), do: [%{}]
  defp sample({:array, inner}, date, datetime), do: [sample(inner, date, datetime)]
  defp sample(type, _date, _datetime) when type in [:map, :object, :reference], do: %{}
  defp sample(_scalar, _date, _datetime), do: "sample"
end
