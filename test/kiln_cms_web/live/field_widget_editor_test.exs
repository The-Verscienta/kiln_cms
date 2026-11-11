defmodule KilnCMSWeb.FieldWidgetEditorTest do
  @moduledoc """
  The content editor's inputs for a field's chosen widget (#2284): a single
  select as radios or buttons, a multiple select as checkboxes, plain text on
  one line — each rendering, saving, and keeping a stored value the options
  no longer list. A field with no widget keeps today's input, which the
  select and text editor tests pin.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "fwe-#{System.unique_integer([:positive])}@example.com"

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

  defp signed_in(conn, admin) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(admin)
  end

  defp uniq, do: System.unique_integer([:positive])

  setup %{conn: conn} do
    admin = authed_admin()

    define!(admin, %{
      name: "season",
      label: "Season",
      field_type: :select,
      widget: "radios",
      options: ["spring", "summer", "autumn"],
      option_labels: %{"spring" => "Spring (early)"},
      position: 0
    })

    define!(admin, %{
      name: "size",
      label: "Size",
      field_type: :select,
      widget: "buttons",
      required: true,
      options: ["s", "m", "l"],
      default: "m",
      position: 1
    })

    define!(admin, %{
      name: "flavours",
      label: "Flavours",
      field_type: :select,
      multiple: true,
      widget: "checkboxes",
      options: ["bitter", "sweet", "sour"],
      max_items: 3,
      position: 2
    })

    define!(admin, %{
      name: "code",
      label: "Code",
      field_type: :text,
      format: :plain,
      widget: "single_line",
      help_text: "One short line",
      position: 3
    })

    page =
      CMS.create_page!(
        %{
          title: "Ginseng",
          slug: "fwe-#{uniq()}",
          custom_fields: %{
            "season" => "summer",
            "flavours" => ["sour", "bitter"],
            "code" => "RS-1"
          }
        },
        actor: admin
      )

    conn = signed_in(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/#{page.id}")
    %{admin: admin, page: page, lv: lv, conn: conn}
  end

  # A record holding `fields`, saved while `field` still listed every value,
  # after which the option list loses the ones not in `options`.
  defp stray!(ctx, field, options, fields) do
    definition =
      CMS.field_definitions_for!(:page, actor: ctx.admin) |> Enum.find(&(&1.name == field))

    CMS.update_field_definition!(
      definition,
      %{options: Enum.uniq(definition.options ++ List.wrap(fields[field]))},
      actor: ctx.admin
    )

    page =
      CMS.create_page!(%{title: "Stray", slug: "fwe-#{uniq()}", custom_fields: fields},
        actor: ctx.admin
      )

    CMS.update_field_definition!(definition, %{options: options}, actor: ctx.admin)
    page
  end

  defp stored(ctx), do: CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields

  defp save(lv), do: lv |> form("#page-editor") |> render_submit()

  defp change(lv, fields),
    do: lv |> form("#page-editor", %{"form" => %{"custom_fields" => fields}}) |> render_change()

  defp names_in(lv, selector) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("name")
  end

  defp values_in(lv, selector) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
  end

  describe "radios" do
    test "a fieldset of one radio per option behind a blank sentinel, labelled", ctx do
      group = "fieldset#custom-field-season[role=radiogroup][data-widget=radios]"
      assert has_element?(ctx.lv, group)
      assert has_element?(ctx.lv, "#{group} > legend#custom-field-season-label", "Season")
      assert has_element?(ctx.lv, ~s(#{group}[aria-labelledby="custom-field-season-label"]))

      # The blank hidden input is the group's first input, so an unchecked
      # group still posts the field.
      assert ["form[custom_fields][season]" | _] = names_in(ctx.lv, "#{group} input")
      assert ["" | _] = values_in(ctx.lv, "#{group} input")
      assert has_element?(ctx.lv, ~s(#{group} input[type=hidden][value=""]))

      # Optional: "— None —" first, then each option by its label.
      assert values_in(ctx.lv, "#{group} input[type=radio]") == ["", "spring", "summer", "autumn"]
      assert has_element?(ctx.lv, ~s(label[for="custom-field-season-opt-none"]), "— None —")
      assert has_element?(ctx.lv, ~s(label[for="custom-field-season-opt-0"]), "Spring (early)")
      assert has_element?(ctx.lv, "#custom-field-season-opt-1[checked]")
      refute has_element?(ctx.lv, "#{group} input[required]")
      refute has_element?(ctx.lv, "select#custom-field-season")
    end

    test "saves the radio chosen, and None clears it", ctx do
      change(ctx.lv, %{"season" => "autumn"})
      save(ctx.lv)
      assert stored(ctx)["season"] == "autumn"

      change(ctx.lv, %{"season" => ""})
      save(ctx.lv)
      refute stored(ctx)["season"]
    end

    test "a stored value the options no longer list is its own checked radio, and kept",
         ctx do
      page = stray!(ctx, "season", ["spring", "summer", "autumn"], %{"season" => "winter"})

      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/content/page/#{page.id}")

      assert values_in(lv, "#custom-field-season input[type=radio]") ==
               ["", "spring", "summer", "autumn", "winter"]

      assert has_element?(lv, "#custom-field-season-opt-3[value=winter][checked]")

      lv |> form("#page-editor") |> render_submit()
      assert CMS.get_page!(page.id, actor: ctx.admin).custom_fields["season"] == "winter"
    end

    test "falls back to the dropdown past the option cap", ctx do
      define!(ctx.admin, %{
        name: "region",
        label: "Region",
        field_type: :select,
        widget: "radios",
        options: Enum.map(1..51, &"r#{&1}"),
        position: 9
      })

      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/content/page/#{ctx.page.id}")

      assert has_element?(lv, "select#custom-field-region")
      refute has_element?(lv, "fieldset#custom-field-region")
    end
  end

  describe "buttons" do
    test "the same radios, drawn as a segmented row; required, with no None", ctx do
      group = "fieldset#custom-field-size[role=radiogroup][data-widget=buttons]"
      assert has_element?(ctx.lv, ~s(#{group}[aria-required="true"]))
      assert has_element?(ctx.lv, "#{group} > legend", "Size")
      assert has_element?(ctx.lv, ~s(#{group} input[type=hidden][value=""]))

      assert values_in(ctx.lv, "#{group} input[type=radio]") == ["s", "m", "l"]
      refute has_element?(ctx.lv, "#custom-field-size-opt-none")

      # A browser requires a radio group through `required` on one radio.
      assert has_element?(ctx.lv, "#custom-field-size-opt-0[required]")
      refute has_element?(ctx.lv, "#custom-field-size-opt-1[required]")

      # Visually hidden radios, each inside its own label.
      assert has_element?(ctx.lv, ~s(label[for="custom-field-size-opt-2"] input.sr-only))
      assert has_element?(ctx.lv, ~s(label[for="custom-field-size-opt-2"]), "l")
    end

    test "saves the button chosen", ctx do
      change(ctx.lv, %{"size" => "l"})
      save(ctx.lv)
      assert stored(ctx)["size"] == "l"
    end
  end

  describe "checkboxes" do
    test "one box per option behind a blank sentinel", ctx do
      group = "fieldset#custom-field-flavours[data-widget=checkboxes]"
      assert has_element?(ctx.lv, "#{group} > legend#custom-field-flavours-label", "Flavours")
      assert ["form[custom_fields][flavours][]" | _] = names_in(ctx.lv, "#{group} input")
      assert has_element?(ctx.lv, ~s(#{group} input[type=hidden][value=""]))

      assert values_in(ctx.lv, "#{group} input[type=checkbox]") == ["bitter", "sweet", "sour"]
      assert has_element?(ctx.lv, "#custom-field-flavours-opt-0[checked]")
      refute has_element?(ctx.lv, "#custom-field-flavours-opt-1[checked]")
      assert has_element?(ctx.lv, "#custom-field-flavours-opt-2[checked]")
      assert has_element?(ctx.lv, ~s(label[for="custom-field-flavours-opt-1"]), "sweet")

      refute has_element?(ctx.lv, "#custom-field-flavours-entry")
    end

    test "saves the ticked boxes in option order, whatever order they were ticked in", ctx do
      change(ctx.lv, %{"flavours" => ["", "sweet", "bitter"]})
      save(ctx.lv)
      assert stored(ctx)["flavours"] == ["bitter", "sweet"]

      change(ctx.lv, %{"flavours" => [""]})
      save(ctx.lv)
      refute Map.has_key?(stored(ctx), "flavours")
    end

    test "says when the field is at its limit", ctx do
      change(ctx.lv, %{"flavours" => ["", "bitter", "sweet", "sour"]})
      assert render(ctx.lv) =~ "At the limit of 3 terms."
    end

    test "a stored term the options no longer list keeps a checked box, and is kept", ctx do
      page =
        stray!(ctx, "flavours", ["bitter", "sweet", "sour"], %{"flavours" => ["umami", "sweet"]})

      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/content/page/#{page.id}")

      assert values_in(lv, "#custom-field-flavours input[type=checkbox]") ==
               ["bitter", "sweet", "sour", "umami"]

      assert has_element?(lv, "#custom-field-flavours-opt-3[value=umami][checked]")

      # Unticked, it keeps its box until the record is saved without it.
      lv
      |> form("#page-editor", %{"form" => %{"custom_fields" => %{"flavours" => ["", "sweet"]}}})
      |> render_change()

      assert has_element?(lv, "#custom-field-flavours-opt-3[value=umami]")
      refute has_element?(lv, "#custom-field-flavours-opt-3[checked]")

      lv
      |> form("#page-editor", %{
        "form" => %{"custom_fields" => %{"flavours" => ["", "sweet", "umami"]}}
      })
      |> render_change()

      lv |> form("#page-editor") |> render_submit()

      assert CMS.get_page!(page.id, actor: ctx.admin).custom_fields["flavours"] == [
               "sweet",
               "umami"
             ]
    end

    test "falls back to tags past the option cap", ctx do
      define!(ctx.admin, %{
        name: "notes",
        label: "Notes",
        field_type: :select,
        multiple: true,
        widget: "checkboxes",
        options: Enum.map(1..51, &"n#{&1}"),
        position: 9
      })

      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/content/page/#{ctx.page.id}")

      assert has_element?(lv, "#custom-field-notes-entry[phx-hook=TermPicker]")
      refute has_element?(lv, "#custom-field-notes input[type=checkbox]")
    end
  end

  describe "single line" do
    test "an input with the textarea's label, help and wiring; saves", ctx do
      assert has_element?(ctx.lv, ~s(input#custom-field-code[type=text][value="RS-1"]))
      assert has_element?(ctx.lv, ~s(label[for="custom-field-code"]), "Code")
      assert render(ctx.lv) =~ "One short line"
      refute has_element?(ctx.lv, "textarea#custom-field-code")

      change(ctx.lv, %{"code" => "RS-2"})
      save(ctx.lv)
      assert stored(ctx)["code"] == "RS-2"
    end

    test "a value holding a line break keeps the textarea, so the break survives", ctx do
      page =
        CMS.create_page!(
          %{title: "Lines", slug: "fwe-#{uniq()}", custom_fields: %{"code" => "one\ntwo"}},
          actor: ctx.admin
        )

      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/content/page/#{page.id}")

      assert has_element?(lv, "textarea#custom-field-code")
      refute has_element?(lv, "input#custom-field-code")

      lv |> form("#page-editor") |> render_submit()
      assert CMS.get_page!(page.id, actor: ctx.admin).custom_fields["code"] == "one\ntwo"
    end
  end
end
