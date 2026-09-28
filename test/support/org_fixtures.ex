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

  @doc """
  Grant `user` the gated `audiences` the only way 1.0 reads them: an
  `OrgMembership` on `org_id` (the default org unless given) carrying them, at
  the user's own editor/viewer tier so the membership changes nothing else.
  `User.audiences` grants nothing since the no-membership fallback was removed
  (#1543). A no-op for `[]`. Returns `user`.
  """
  def grant_audiences(user, audiences, org_id \\ nil)
  def grant_audiences(user, [], _org_id), do: user

  def grant_audiences(user, audiences, org_id) do
    role = if user.role in [:editor, :viewer], do: user.role, else: :viewer

    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      organization_id: org_id || KilnCMS.Accounts.default_org_id(),
      user_id: user.id,
      role: role,
      audiences: audiences
    })

    user
  end
end
