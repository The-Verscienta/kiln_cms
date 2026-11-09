defmodule KilnCMSWeb.ScalarListFieldEditorTest do
  @moduledoc """
  The content editor's input for a typed scalar list (#2289) — a `multiple`
  number, date, date-time or link field: one input of the field's own kind
  per item, an add box that adds on Enter (and, for a date or time, on its
  Add button), removal and reordering as edits of the form, repeats judged
  as the list stores them, and nothing at all on a field the editor's write
  grant leaves out.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, extra \\ %{}) do
    email = "slfe-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        extra
      )
    )

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

  defp signed_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  setup %{conn: conn} do
    admin = authed_user(:admin)

    define!(admin, %{
      name: "scores",
      label: "Scores",
      field_type: :integer,
      multiple: true,
      max_items: 3,
      position: 0
    })

    define!(admin, %{
      name: "event_dates",
      label: "Event dates",
      field_type: :date,
      multiple: true,
      position: 1
    })

    define!(admin, %{
      name: "slots",
      label: "Slots",
      field_type: :datetime,
      multiple: true,
      position: 2
    })

    define!(admin, %{
      name: "weights",
      label: "Weights",
      field_type: :float,
      multiple: true,
      position: 3
    })

    define!(admin, %{name: "homepage", label: "Homepage", field_type: :url, position: 4})

    page =
      CMS.create_page!(
        %{
          title: "Retreat",
          slug: "slfe-#{System.unique_integer([:positive])}",
          custom_fields: %{
            "scores" => [3],
            "event_dates" => ["2026-03-01", "2026-05-01"],
            "slots" => ["2026-03-01T10:00:00"],
            "homepage" => "https://example.com"
          }
        },
        actor: admin
      )

    {:ok, lv, _html} = conn |> signed_in(admin) |> live(~p"/editor/content/page/#{page.id}")
    %{admin: admin, page: page, lv: lv, conn: conn}
  end

  defp item(field, n), do: "#custom-field-#{field}-#{n}"

  defp item_value(lv, field, n) do
    lv
    |> element(item(field, n))
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("value")
    |> List.first()
  end

  defp add(lv, field, value) do
    lv
    |> element("#custom-field-#{field}-entry")
    |> render_hook("list_item_add", %{"field" => field, "item" => value})
  end

  defp stored(ctx), do: CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields

  describe "the inputs" do
    test "each item is the field's own kind of input, without required", ctx do
      assert has_element?(
               ctx.lv,
               ~s(#{item("scores", 0)}[type=number][name="form[custom_fields][scores][]"][value="3"])
             )

      assert has_element?(ctx.lv, ~s(#{item("event_dates", 1)}[type=date][value="2026-05-01"]))
      assert has_element?(ctx.lv, ~s(#{item("slots", 0)}[type=datetime-local]))
      refute has_element?(ctx.lv, "#{item("event_dates", 0)}[required]")

      assert has_element?(
               ctx.lv,
               ~s(#custom-field-event_dates-items[phx-hook=Sortable][data-sort-event=list_item_reorder])
             )
    end

    test "a number's box adds on Enter in lines mode; a date's has an Add button", ctx do
      assert has_element?(
               ctx.lv,
               ~s(#custom-field-scores-entry[type=number][phx-hook=TermPicker][data-split=lines])
             )

      refute has_element?(ctx.lv, "#custom-field-scores-add")

      assert has_element?(
               ctx.lv,
               ~s(#custom-field-event_dates-entry[type=date][phx-hook=TermPicker][data-split=none])
             )

      assert has_element?(ctx.lv, "#custom-field-event_dates-add[data-list-add]", "Add")

      assert has_element?(
               ctx.lv,
               ~s(#custom-field-slots-entry[type=datetime-local][data-split=none])
             )
    end

    test "a float list's inputs take any step", ctx do
      add(ctx.lv, "weights", "2.5")

      assert has_element?(ctx.lv, ~s(#{item("weights", 0)}[type=number][step=any][value="2.5"]))
      assert has_element?(ctx.lv, ~s(#custom-field-weights-entry[type=number][step=any]))
    end

    test "a single typed field is still one input", ctx do
      assert has_element?(
               ctx.lv,
               ~s(input#custom-field-homepage[type=url][name="form[custom_fields][homepage]"])
             )

      refute has_element?(ctx.lv, "#custom-field-homepage-entry")
    end
  end

  describe "editing the list" do
    test "a number repeats; a date does not", ctx do
      add(ctx.lv, "scores", "3")
      assert item_value(ctx.lv, "scores", 1) == "3"

      add(ctx.lv, "event_dates", "2026-03-01")
      refute has_element?(ctx.lv, item("event_dates", 2))

      add(ctx.lv, "event_dates", "2026-07-04")
      assert item_value(ctx.lv, "event_dates", 2) == "2026-07-04"
    end

    test "a repeat is judged as the list stores it", ctx do
      # The picker's `T10:00` is the stored `T10:00:00`.
      add(ctx.lv, "slots", "2026-03-01T10:00")
      refute has_element?(ctx.lv, item("slots", 1))

      add(ctx.lv, "slots", "2026-03-01T11:00")
      assert item_value(ctx.lv, "slots", 1) == "2026-03-01T11:00"
    end

    test "at max_items an add is ignored and the add box is gone", ctx do
      add(ctx.lv, "scores", "4")
      add(ctx.lv, "scores", "5")

      assert item_value(ctx.lv, "scores", 2) == "5"
      refute has_element?(ctx.lv, "#custom-field-scores-entry")
      assert render(ctx.lv) =~ "At the limit of 3 items."

      render_hook(ctx.lv, "list_item_add", %{"field" => "scores", "item" => "6"})
      refute has_element?(ctx.lv, item("scores", 3))
    end

    test "removes and reorders; an order that is no permutation changes nothing", ctx do
      add(ctx.lv, "event_dates", "2026-07-04")

      ctx.lv
      |> element("#custom-field-event_dates-items")
      |> render_hook("list_item_reorder", %{"field" => "event_dates", "order" => ["2", "0"]})

      assert item_value(ctx.lv, "event_dates", 0) == "2026-03-01"

      ctx.lv
      |> element("#custom-field-event_dates-items")
      |> render_hook("list_item_reorder", %{"field" => "event_dates", "order" => ["2", "0", "1"]})

      assert item_value(ctx.lv, "event_dates", 0) == "2026-07-04"
      assert item_value(ctx.lv, "event_dates", 1) == "2026-03-01"

      ctx.lv
      |> element("#cf-item-event_dates-1 button[phx-click=list_item_remove]")
      |> render_click()

      assert item_value(ctx.lv, "event_dates", 1) == "2026-05-01"
      refute has_element?(ctx.lv, item("event_dates", 2))
    end

    test "an item that is not a date is shown and named by the field's error", ctx do
      html = add(ctx.lv, "event_dates", "someday")

      assert item_value(ctx.lv, "event_dates", 2) == "someday"
      assert html =~ "item 3 must be a date"
    end

    test "saves the list JSON-native, in screen order", ctx do
      add(ctx.lv, "scores", "3")
      add(ctx.lv, "event_dates", "2026-07-04")

      ctx.lv
      |> element("#custom-field-event_dates-items")
      |> render_hook("list_item_reorder", %{"field" => "event_dates", "order" => ["2", "0", "1"]})

      ctx.lv |> form("#page-editor") |> render_submit()

      assert %{
               "scores" => [3, 3],
               "event_dates" => ["2026-07-04", "2026-03-01", "2026-05-01"]
             } = stored(ctx)
    end
  end

  describe "a field the editor's write grant leaves out" do
    setup ctx do
      editor =
        authed_user(:editor, %{field_grants: %{"page" => ["title", "custom_fields.scores"]}})

      {:ok, lv, _html} =
        ctx.conn
        |> recycle()
        |> signed_in(editor)
        |> live(~p"/editor/content/page/#{ctx.page.id}")

      %{lv: lv}
    end

    test "renders read-only, and its list events change nothing", ctx do
      assert has_element?(ctx.lv, "#cf-read-only-event_dates")

      render_hook(ctx.lv, "list_item_add", %{"field" => "event_dates", "item" => "2026-07-04"})
      refute has_element?(ctx.lv, item("event_dates", 2))

      render_hook(ctx.lv, "list_item_remove", %{"field" => "event_dates", "index" => "0"})
      assert item_value(ctx.lv, "event_dates", 0) == "2026-03-01"

      render_hook(ctx.lv, "list_item_reorder", %{"field" => "event_dates", "order" => ["1", "0"]})
      assert item_value(ctx.lv, "event_dates", 0) == "2026-03-01"
    end

    test "a granted list field still takes its events", ctx do
      add(ctx.lv, "scores", "7")
      assert item_value(ctx.lv, "scores", 1) == "7"
    end
  end
end
