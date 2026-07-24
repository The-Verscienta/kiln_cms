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
  def load(query, _opts, _context) do
    if Ash.Resource.Info.attribute(query.resource, :type_definition_id),
      do: [:slug, :path_alias, :type_definition_id],
      else: [:slug, :path_alias]
  end

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      case Slugs.descriptor_for_record(record) do
        nil -> nil
        ct -> Slugs.public_path_for(ct, record)
      end
    end)
  end
end
