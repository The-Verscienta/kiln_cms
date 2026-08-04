defmodule KilnCMS.Analytics.FunnelTest do
  @moduledoc """
  `Funnel` (#621, phase 4 of `docs/advanced-analytics-plan.md`) — the first
  genuinely writable resource in `KilnCMS.Analytics`: admin-only
  create/update/destroy, `OrgEditor` read, org-tenanted like everything else
  in the domain.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.Funnel
  alias KilnCMS.Analytics.FunnelStep

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "funnel-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org(name) do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp slug, do: "funnel-#{System.unique_integer([:positive])}"

  test "an admin can create, update and destroy a funnel" do
    admin = user(:admin)

    funnel = Analytics.create_funnel!(%{name: "Signup", slug: slug()}, actor: admin)
    assert funnel.active == true

    updated = Analytics.update_funnel!(funnel, %{active: false}, actor: admin)
    assert updated.active == false

    assert :ok = Analytics.destroy_funnel(updated, actor: admin)
    assert Funnel |> Ash.read!(authorize?: false) == []
  end

  test "no non-admin role may create, update or destroy a funnel" do
    create_input = %{name: "Signup", slug: slug()}

    refute Ash.can?({Funnel, :create, create_input}, user(:editor))
    refute Ash.can?({Funnel, :create, create_input}, user(:viewer))
    refute Ash.can?({Funnel, :create, create_input}, nil)

    funnel = Analytics.create_funnel!(create_input, authorize?: false)

    refute Ash.can?({funnel, :update, %{active: false}}, user(:editor))
    refute Ash.can?({funnel, :destroy}, user(:editor))
  end

  test "funnels are visible to editors/admins but not viewers" do
    Analytics.create_funnel!(%{name: "Signup", slug: slug()}, authorize?: false)

    assert [_] = Ash.read!(Funnel, actor: user(:editor))
    assert [_] = Ash.read!(Funnel, actor: user(:admin))
    assert [] = Ash.read!(Funnel, actor: user(:viewer))
  end

  test "slug must be lowercase letters, digits and dashes" do
    assert {:error, error} =
             Analytics.create_funnel(%{name: "Signup", slug: "Not A Slug!"}, authorize?: false)

    assert %Ash.Error.Invalid{} = error
  end

  test "slug is unique within an org, shareable across orgs" do
    a = org("orga")
    b = org("orgb")
    admin = user(:admin)
    dup_slug = slug()

    fa = Analytics.create_funnel!(%{name: "A", slug: dup_slug}, actor: admin, tenant: a)
    fb = Analytics.create_funnel!(%{name: "B", slug: dup_slug}, actor: admin, tenant: b)

    assert fa.org_id == a.id
    assert fb.org_id == b.id

    assert {:error, _} =
             Analytics.create_funnel(%{name: "dup", slug: dup_slug}, actor: admin, tenant: a)
  end

  test "a funnel is invisible outside its own org" do
    a = org("orga")
    b = org("orgb")
    admin = user(:admin)

    Analytics.create_funnel!(%{name: "A only", slug: slug()}, actor: admin, tenant: a)

    assert [_] = Ash.read!(Funnel, actor: admin, tenant: a)
    assert [] = Ash.read!(Funnel, actor: admin, tenant: b)
  end

  test "steps load in position order" do
    funnel = Analytics.create_funnel!(%{name: "Signup", slug: slug()}, authorize?: false)

    Analytics.create_funnel_step!(
      %{funnel_id: funnel.id, content_type: "page", content_id: Ash.UUID.generate(), position: 1},
      authorize?: false
    )

    Analytics.create_funnel_step!(
      %{funnel_id: funnel.id, content_type: "page", content_id: Ash.UUID.generate(), position: 0},
      authorize?: false
    )

    loaded = Ash.load!(funnel, [:steps], authorize?: false)
    assert Enum.map(loaded.steps, & &1.position) == [0, 1]
  end

  test "destroying a funnel cascades to its steps" do
    funnel = Analytics.create_funnel!(%{name: "Signup", slug: slug()}, authorize?: false)

    Analytics.create_funnel_step!(
      %{funnel_id: funnel.id, content_type: "page", content_id: Ash.UUID.generate()},
      authorize?: false
    )

    Analytics.destroy_funnel(funnel, authorize?: false)

    assert Ash.read!(FunnelStep, authorize?: false) == []
  end
end
