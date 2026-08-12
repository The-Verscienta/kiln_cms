defmodule KilnCMS.CMS.Calculations.PublicPath do
  @moduledoc """
  The record's full public URL path — the type's delivery prefix plus the slug
  (`/blog/my-post`, `/about`) — exposed as the `path` field on the headless
  read APIs, so front ends can link to content without hard-coding Kiln's URL
  scheme. Dynamic entries resolve their prefix through their type definition.
  """
  use Ash.Resource.Calculation

  alias KilnCMS.CMS.Slugs

  @impl true
  def load(query, _opts, _context), do: Slugs.path_calculation_loads(query)

  @impl true
  def calculate(records, _opts, _context) do
    records
    |> Slugs.descriptors_for_records()
    |> Enum.zip(records)
    |> Enum.map(fn
      {nil, _record} -> nil
      {ct, record} -> Slugs.public_path_for(ct, record)
    end)
  end
end
