defmodule KilnCMS.OrgFixtures do
  @moduledoc """
  Shared multi-tenant test scaffolding (#557): seeds an `Organization` for
  tenant-hosted-request tests, bypassing the `multitenancy_enabled` create
  guard the same way `Ash.Seed` is used throughout the multi-tenancy suite.
  """

  alias KilnCMS.Accounts.Organization

  @doc """
  Seeds an org named/slugged from `slug` (suffixed with a unique integer so
  concurrent tests never collide), merging any `opts` (e.g. `custom_domain:`)
  into the record.
  """
  def org(slug, opts \\ []) do
    Ash.Seed.seed!(
      Organization,
      Map.merge(
        %{
          name: "Org #{slug}",
          slug: "#{slug}-#{System.unique_integer([:positive])}",
          status: :active
        },
        Map.new(opts)
      )
    )
  end
end
