defmodule KilnCMS.CMS.Calculations.LatestEditLookup do
  @moduledoc """
  The private `latest_edit` calculation: `%{severity: atom, at: DateTime.t()}`
  or `nil` for each record (`KilnCMS.CMS.LatestEdit`). `latest_edit_severity`
  and `latest_edit_at` both load it, so selecting either or both runs one
  version query per page of records, not one each.
  """
  use Ash.Resource.Calculation

  alias KilnCMS.CMS.LatestEdit

  @impl true
  def load(_query, _opts, _context), do: [:state, :org_id]

  @impl true
  def calculate(records, _opts, _context) do
    edits = LatestEdit.for_records(records)
    Enum.map(records, &Map.get(edits, &1.id))
  end
end
