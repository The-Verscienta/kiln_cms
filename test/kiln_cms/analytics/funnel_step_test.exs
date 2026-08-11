defmodule KilnCMS.Analytics.FunnelStepTest do
  @moduledoc """
  `FunnelStep` (#621) — one ordered, polymorphic content reference on a
  `Funnel`, admin-only to write, editor/admin to read (mirrors `Funnel`'s
  policy block, since a step is meaningless without its parent's authz).
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.FunnelStep

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "funnel-step-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp funnel!(opts \\ [authorize?: false]) do
    Analytics.create_funnel!(
      %{name: "Signup", slug: "funnel-#{System.unique_integer([:positive])}"},
      opts
    )
  end

  test "an admin can create, update and destroy a step" do
    admin = user(:admin)
    funnel = funnel!(actor: admin)
    content_id = Ash.UUID.generate()

    step =
      Analytics.create_funnel_step!(
        %{funnel_id: funnel.id, content_type: "page", content_id: content_id, position: 0},
        actor: admin
      )

    assert step.content_type == "page"
    assert step.content_id == content_id

    updated = Analytics.update_funnel_step!(step, %{position: 3}, actor: admin)
    assert updated.position == 3

    assert :ok = Analytics.destroy_funnel_step(updated, actor: admin)
    assert Ash.read!(FunnelStep, authorize?: false) == []
  end

  test "no non-admin role may create, update or destroy a step" do
    funnel = funnel!()

    create_input = %{
      funnel_id: funnel.id,
      content_type: "page",
      content_id: Ash.UUID.generate()
    }

    refute Ash.can?({FunnelStep, :create, create_input}, user(:editor))
    refute Ash.can?({FunnelStep, :create, create_input}, user(:viewer))
    refute Ash.can?({FunnelStep, :create, create_input}, nil)

    step = Analytics.create_funnel_step!(create_input, authorize?: false)

    refute Ash.can?({step, :update, %{position: 1}}, user(:editor))
    refute Ash.can?({step, :destroy}, user(:editor))
  end

  test "steps are visible to editors/admins but not viewers" do
    funnel = funnel!()

    Analytics.create_funnel_step!(
      %{funnel_id: funnel.id, content_type: "page", content_id: Ash.UUID.generate()},
      authorize?: false
    )

    assert [_] = Ash.read!(FunnelStep, actor: user(:editor))
    assert [_] = Ash.read!(FunnelStep, actor: user(:admin))
    assert [] = Ash.read!(FunnelStep, actor: user(:viewer))
  end

  describe "for_funnel" do
    defp for_funnel!(funnel_id, opts) do
      FunnelStep
      |> Ash.Query.for_read(:for_funnel, %{funnel_id: funnel_id})
      |> Ash.read!(opts)
    end

    test "returns only this funnel's steps, in position order" do
      funnel = funnel!()
      other_funnel = funnel!()

      Analytics.create_funnel_step!(
        %{
          funnel_id: funnel.id,
          content_type: "page",
          content_id: Ash.UUID.generate(),
          position: 1
        },
        authorize?: false
      )

      first =
        Analytics.create_funnel_step!(
          %{
            funnel_id: funnel.id,
            content_type: "page",
            content_id: Ash.UUID.generate(),
            position: 0
          },
          authorize?: false
        )

      Analytics.create_funnel_step!(
        %{
          funnel_id: other_funnel.id,
          content_type: "page",
          content_id: Ash.UUID.generate(),
          position: 0
        },
        authorize?: false
      )

      steps = for_funnel!(funnel.id, authorize?: false)
      assert [%{id: first_id}, _second] = steps
      assert first_id == first.id
    end
  end
end
