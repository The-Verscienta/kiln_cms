defmodule KilnCMSWeb.FieldConditionsEditorTest do
  @moduledoc """
  Conditional custom fields in the content editor (#2277): the server seeds
  each rule onto the field's wrapper (`data-cf-*`) and its starting state
  (hidden, `required`); `FieldConditions` (assets/js) takes over from there,
  so the save must accept a hidden required field and refuse a visible one.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  defp admin do
    email = "fce-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => "password123456"},
        []
      )

    user
  end

  defp field!(admin, attrs),
    do: CMS.create_field_definition!(Map.merge(%{content_type: :page}, attrs), actor: admin)

  defp open(conn, admin, fields) do
    page =
      CMS.create_page!(
        %{
          title: "Cond",
          slug: "fce-#{System.unique_integer([:positive])}",
          custom_fields: fields
        },
        actor: admin
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/#{page.id}")
    {lv, page}
  end

  defp stored(page),
    do: CMS.get_page!(page.id, authorize?: false).custom_fields

  defp attr(lv, selector, name) do
    lv |> element(selector) |> render() |> Floki.parse_fragment!() |> Floki.attribute(name)
  end

  defp classes(lv, selector), do: attr(lv, selector, "class") |> List.first() |> String.split()

  setup do
    admin = admin()
    rule = %{"field" => "kind", "op" => "eq", "value" => "other"}

    field!(admin, %{
      name: "kind",
      label: "Kind",
      field_type: :select,
      options: ["a", "other"],
      position: 0
    })

    field!(admin, %{
      name: "detail",
      label: "Detail",
      field_type: :string,
      visible_when: rule,
      required_when: rule,
      position: 1
    })

    field!(admin, %{name: "plain", label: "Plain", field_type: :string, position: 2})
    %{admin: admin, rule: rule}
  end

  test "a conditional field carries its rules and starts hidden while the rule is false", ctx do
    {lv, _page} = open(build_conn(), ctx.admin, %{"kind" => "a"})

    assert ["FieldConditions"] = attr(lv, "#cf-cond-detail", "phx-hook")
    assert [json] = attr(lv, "#cf-cond-detail", "data-cf-visible-when")
    assert Jason.decode!(json) == ctx.rule
    assert [^json] = attr(lv, "#cf-cond-detail", "data-cf-required-when")
    assert ["form[custom_fields]"] = attr(lv, "#cf-cond-detail", "data-cf-prefix")
    assert ["true"] = attr(lv, "#cf-cond-detail", "aria-hidden")
    assert "hidden" in classes(lv, "#cf-cond-detail")

    # No required on the input while hidden, and no wrapper on an unconditional field.
    assert [] = attr(lv, "#custom-field-detail", "required")
    refute has_element?(lv, "#cf-cond-plain")
    refute has_element?(lv, "#cf-cond-kind")
  end

  test "it starts shown, and required, while the rule is true", ctx do
    {lv, _page} = open(build_conn(), ctx.admin, %{"kind" => "other", "detail" => "x"})

    refute "hidden" in classes(lv, "#cf-cond-detail")
    assert [] = attr(lv, "#cf-cond-detail", "aria-hidden")
    assert [_] = attr(lv, "#custom-field-detail", "required")
  end

  test "a hidden required field does not block the save, and keeps its stored value", ctx do
    {lv, page} = open(build_conn(), ctx.admin, %{"kind" => "a", "detail" => "kept"})

    lv |> form("#page-editor") |> render_submit()

    assert %{"kind" => "a", "detail" => "kept"} = stored(page)
  end

  test "a visible required-when field left empty is refused", ctx do
    {lv, page} = open(build_conn(), ctx.admin, %{"kind" => "a"})

    lv
    |> form("#page-editor", %{"form" => %{"custom_fields" => %{"kind" => "other"}}})
    |> render_change()

    lv |> form("#page-editor") |> render_submit()

    assert has_element?(lv, "#custom-field-detail-errors", "required")
    refute Map.has_key?(stored(page), "detail")

    lv
    |> form("#page-editor", %{"form" => %{"custom_fields" => %{"detail" => "now"}}})
    |> render_submit()

    assert %{"kind" => "other", "detail" => "now"} = stored(page)
  end

  test "a change that makes the rule false hides the field in the next render", ctx do
    {lv, _page} = open(build_conn(), ctx.admin, %{"kind" => "other", "detail" => "x"})

    lv
    |> form("#page-editor", %{"form" => %{"custom_fields" => %{"kind" => "a"}}})
    |> render_change()

    assert "hidden" in classes(lv, "#cf-cond-detail")
  end

  describe "in a group row" do
    setup ctx do
      group =
        field!(ctx.admin, %{
          name: "dosages",
          label: "Dosages",
          field_type: :group,
          multiple: true,
          position: 3
        })

      sub = fn attrs ->
        CMS.create_field_definition!(Map.put(attrs, :group_of_id, group.id), actor: ctx.admin)
      end

      sub.(%{
        name: "unit",
        label: "Unit",
        field_type: :select,
        options: ["g", "other"],
        position: 0
      })

      sub.(%{
        name: "unit_note",
        label: "Unit note",
        field_type: :string,
        visible_when: %{"field" => "unit", "op" => "eq", "value" => "other"},
        position: 1
      })

      :ok
    end

    test "each row reads its own siblings", ctx do
      {lv, _page} =
        open(build_conn(), ctx.admin, %{
          "kind" => "a",
          "dosages" => [%{"unit" => "g"}, %{"unit" => "other"}]
        })

      assert "hidden" in classes(lv, "#cf-cond-dosages-0-unit_note")
      refute "hidden" in classes(lv, "#cf-cond-dosages-1-unit_note")

      assert ["form[custom_fields][dosages][1]"] =
               attr(lv, "#cf-cond-dosages-1-unit_note", "data-cf-prefix")

      # A sub-field never carries required-when to the browser.
      assert [] = attr(lv, "#cf-cond-dosages-1-unit_note", "data-cf-required-when")
    end
  end
end
