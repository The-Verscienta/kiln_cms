defmodule KilnCMS.Repo.Migrations.AddAcupunctureContentSearchVectors do
  @moduledoc """
  Trigger-maintained `search_vector` columns for the four content types added
  in `add_acupuncture_content_types` — see `KilnCMS.Migrations` for why
  `mix ash.codegen` cannot generate these.
  """
  use Ecto.Migration

  import KilnCMS.Migrations

  @tables ~w(conditions team_members testimonials faqs)

  def up do
    Enum.each(@tables, &add_search_vector/1)
  end

  def down do
    Enum.each(@tables, &drop_search_vector/1)
  end
end
