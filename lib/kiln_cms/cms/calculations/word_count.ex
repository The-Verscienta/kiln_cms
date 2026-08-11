# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule KilnCMS.CMS.Calculations.WordCount do
  @moduledoc """
  Calculates the total word count across a content resource's embedded block
  tree (`blocks`), via `KilnCMS.CMS.BlockText`.

  Expands reusable fragments before counting so a page whose body is a fragment
  reports the fragment's words, not zero — matching the `{{ reading_time(body) }}`
  computed field which is evaluated inside `Engine.fire/2` against the already-
  expanded tree.
  """
  use Ash.Resource.Calculation

  alias KilnCMS.CMS.BlockText
  alias KilnCMS.CMS.Fragments
  alias KilnCMS.CMS.TypedBlocks

  @impl true
  def load(_query, _opts, _context), do: [:blocks]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      case Map.get(record, :blocks) do
        %Ash.NotLoaded{} ->
          0

        nil ->
          0

        blocks when is_list(blocks) ->
          org_id = Map.get(record, :org_id) || KilnCMS.Accounts.default_org_id()

          ancestry =
            case Map.get(record, :id) do
              nil ->
                []

              id ->
                case maybe_document_type(record) do
                  nil -> []
                  type -> [{to_string(type), id}]
                end
            end

          blocks
          |> TypedBlocks.to_typed()
          |> Fragments.expand(org_id,
            audiences: audiences_for(record),
            ancestry: ancestry
          )
          |> BlockText.word_count()

        _ ->
          0
      end
    end)
  end

  defp maybe_document_type(record) do
    KilnCMS.Firing.Engine.document_type(record)
  rescue
    _ -> nil
  end

  defp audiences_for(record) do
    audience = Map.get(record, :audience) || Map.get(record, "audience")

    cond do
      is_nil(audience) -> []
      audience == :public -> []
      audience == "public" -> []
      is_atom(audience) -> [audience]
      is_binary(audience) -> [String.to_atom(audience)]
      true -> []
    end
  end
end
