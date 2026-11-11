defmodule KilnCMS.CMS.Calculations.LatestEditSeverity do
  @moduledoc """
  `latest_edit_severity`: the severity (`:critical | :notable | :routine`) of
  the document's latest safety edit, or `nil` (`KilnCMS.CMS.LatestEdit`).
  `nil` unless the document is currently published. Batched: shares the
  one version query per page of the private `latest_edit` calculation.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:latest_edit]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, &(&1.latest_edit && &1.latest_edit.severity))
  end
end
