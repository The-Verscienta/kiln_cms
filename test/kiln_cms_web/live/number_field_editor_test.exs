defmodule KilnCMSWeb.NumberFieldEditorTest do
  @moduledoc """
  The content editor's inputs for a number with options (#2432): the `step`
  attribute, `prefix`/`suffix` beside the box, and the range slider with its
  server-side blank state — a blank slider field draws a "Set a value" button
  rather than an input that would submit its minimum on the first unrelated
  edit.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "nfe-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp define!(admin, attrs),
    do: CMS.create_field_definition!(Map.put(attrs, :content_type, :page), actor: admin)

  setup %{conn: conn} do
    admin = authed_admin()

    define!(admin, %{
      name: "dose",
      label: "Dose",
      field_type: :float,
      step: 0.5,
      suffix: "mg",
      validation: %{"min" => 0, "max" => 10},
      widget: "slider",
      position: 0
    })

    define!(admin, %{
      name: "level",
      label: "Level",
      field_type: :integer,
      required: true,
      validation: %{"min" => 1, "max" => 5},
      widget: "slider",
      position: 1
    })

    define!(admin, %{
      name: "price",
      label: "Price",
      field_type: :integer,
      step: 5,
      prefix: "$",
      suffix: "USD",
      position: 2
    })

    define!(admin, %{name: "weight", label: "Weight", field_type: :float, position: 3})

    define!(admin, %{
      name: "sizes",
      label: "Sizes",
      field_type: :integer,
      multiple: true,
      step: 2,
      suffix: "cm",
      position: 4
    })

    page =
      CMS.create_page!(
        %{
          title: "Dosing",
          slug: "nfe-#{System.unique_integer([:positive])}",
          custom_fields: %{"level" => 3, "sizes" => [10, 12]}
        },
        actor: admin
      )

    {:ok, lv, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)
      |> live(~p"/editor/content/page/#{page.id}")

    %{admin: admin, page: page, lv: lv}
  end

  defp stored(ctx), do: CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields

  describe "the number input" do
    test "carries the step and draws the prefix and suffix beside it", %{lv: lv} do
      assert has_element?(lv, ~s(#custom-field-price[type=number][step="5"]))
      assert has_element?(lv, "#custom-field-price-prefix", "$")
      assert has_element?(lv, "#custom-field-price-suffix", "USD")

      assert has_element?(
               lv,
               ~s(#custom-field-price[aria-describedby~="custom-field-price-suffix"])
             )
    end

    test "a float with no step keeps step any, and no units draws none", %{lv: lv} do
      assert has_element?(lv, ~s(#custom-field-weight[step=any]))
      refute has_element?(lv, "#custom-field-weight-prefix")
      refute has_element?(lv, "#custom-field-weight-suffix")
    end

    test "a list of numbers: each item takes the step and the suffix", %{lv: lv} do
      assert has_element?(lv, ~s(#custom-field-sizes-0[step="2"]))
      assert has_element?(lv, "#custom-field-sizes-0-suffix", "cm")
      refute has_element?(lv, "#custom-field-sizes[type=range]")
    end
  end

  describe "the slider" do
    test "a set value draws a range input with its bounds, step and readout", %{lv: lv} do
      assert has_element?(
               lv,
               ~s(#custom-field-level[type=range][min="1"][max="5"][step="1"][value="3"])
             )

      assert has_element?(lv, "#custom-field-level-readout", "3")
    end

    test "a blank field draws a button, not an input that would submit its minimum", %{
      lv: lv
    } do
      assert has_element?(lv, "#custom-field-dose[phx-click=number_field_set]", "Set a value")
      refute has_element?(lv, "input#custom-field-dose")
    end

    test "an unrelated edit writes no value for a blank slider field", ctx do
      ctx.lv
      |> form("#page-editor", %{"form" => %{"title" => "Dosing, revised"}})
      |> render_change()

      ctx.lv |> form("#page-editor") |> render_submit()

      assert CMS.get_page!(ctx.page.id, actor: ctx.admin).title == "Dosing, revised"
      refute Map.has_key?(stored(ctx), "dose")
    end

    test "Set a value stores the minimum; Clear removes it again", ctx do
      ctx.lv |> element("#custom-field-dose") |> render_click()

      assert has_element?(ctx.lv, ~s(#custom-field-dose[type=range][value="0.0"][step="0.5"]))
      assert has_element?(ctx.lv, "#custom-field-dose-readout", "0.0 mg")

      ctx.lv |> form("#page-editor") |> render_submit()
      assert stored(ctx)["dose"] == 0

      ctx.lv |> element("#custom-field-dose-clear") |> render_click()
      assert has_element?(ctx.lv, "#custom-field-dose[phx-click=number_field_set]")

      ctx.lv |> form("#page-editor") |> render_submit()
      refute Map.has_key?(stored(ctx), "dose")
    end

    test "a required field has no Clear", %{lv: lv} do
      refute has_element?(lv, "#custom-field-level-clear")
      refute has_element?(lv, "#custom-field-dose-clear")
    end

    test "a forged clear of a required field, or of a field that is no slider, changes nothing",
         ctx do
      render_hook(ctx.lv, "number_field_clear", %{"field" => "level"})
      assert has_element?(ctx.lv, "#custom-field-level[type=range][value=\"3\"]")

      render_hook(ctx.lv, "number_field_set", %{"field" => "price"})
      render_hook(ctx.lv, "number_field_set", %{"field" => "sizes"})
      render_hook(ctx.lv, "number_field_set", %{"field" => "no_such_field"})
      ctx.lv |> form("#page-editor") |> render_submit()

      refute Map.has_key?(stored(ctx), "price")
      assert stored(ctx)["sizes"] == [10, 12]
    end

    test "a stored value outside the bounds draws the plain number input, unclamped", ctx do
      # The bounds tightened after the value was stored.
      level =
        :page
        |> CMS.field_definitions_for!(authorize?: false)
        |> Enum.find(&(&1.name == "level"))

      CMS.update_field_definition!(level, %{validation: %{"min" => 1, "max" => 2}},
        actor: ctx.admin
      )

      {:ok, lv, _html} =
        build_conn_for(ctx.admin) |> live(~p"/editor/content/page/#{ctx.page.id}")

      assert has_element?(lv, ~s(#custom-field-level[type=number][value="3"]))
      refute has_element?(lv, "#custom-field-level[type=range]")
    end
  end

  defp build_conn_for(admin) do
    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(admin)
  end
end
