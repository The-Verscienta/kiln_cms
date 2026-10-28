defmodule KilnCMSWeb.SelectAndTextFieldEditorTest do
  @moduledoc """
  The content editor's inputs for a `:select` holding several terms (the tag
  picker: chips added, removed and reordered as edits of the form, suggesting
  the options and the terms in use) and for a `:text` field (the TipTap field
  editor over a hidden input, or the plain textarea), and the fields admin's
  controls for both.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "stfe-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp define!(admin, attrs),
    do: CMS.create_field_definition!(Map.put(attrs, :content_type, :page), actor: admin)

  defp signed_in(conn, admin) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(admin)
  end

  setup %{conn: conn} do
    admin = authed_admin()

    define!(admin, %{
      name: "properties",
      label: "Western properties",
      field_type: :select,
      multiple: true,
      allow_custom: true,
      options: ["adaptogen", "tonic"],
      max_items: 3,
      position: 0
    })

    define!(admin, %{name: "uses", label: "Uses", field_type: :text, position: 1})

    define!(admin, %{
      name: "code",
      label: "Code",
      field_type: :text,
      format: :plain,
      position: 2
    })

    define!(admin, %{name: "legacy", label: "Legacy", field_type: :text, position: 3})

    # A term in use on another record, which the picker suggests.
    CMS.create_page!(
      %{
        title: "Other",
        slug: "stfe-#{System.unique_integer([:positive])}",
        custom_fields: %{"properties" => ["nervine"]}
      },
      actor: admin
    )

    page =
      CMS.create_page!(
        %{
          title: "Ginseng",
          slug: "stfe-#{System.unique_integer([:positive])}",
          custom_fields: %{
            "properties" => ["tonic"],
            "uses" => "<p>Ren Shen <strong>tonifies</strong></p>",
            "code" => "RS-1",
            "legacy" => ~s(["a","b"])
          }
        },
        actor: admin
      )

    conn = signed_in(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/#{page.id}")
    %{admin: admin, page: page, lv: lv, conn: conn}
  end

  defp chip(n), do: "#cf-term-properties-#{n}"
  defp stored(ctx), do: CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields

  describe "the tag picker" do
    test "shows the chosen terms as chips and suggests the rest", ctx do
      assert has_element?(ctx.lv, chip(0), "tonic")
      assert has_element?(ctx.lv, ~s(#{chip(0)} input[type=hidden][value=tonic]))
      refute has_element?(ctx.lv, chip(1))

      assert has_element?(
               ctx.lv,
               ~s(#custom-field-properties-entry[phx-hook=TermPicker][data-count="1"])
             )

      # Options, then the terms in use, less what is already chosen.
      assert has_element?(
               ctx.lv,
               ~s(#custom-field-properties-suggestions option[value=adaptogen])
             )

      assert has_element?(ctx.lv, ~s(#custom-field-properties-suggestions option[value=nervine]))
      refute has_element?(ctx.lv, ~s(#custom-field-properties-suggestions option[value=tonic]))
    end

    test "adds, removes and reorders terms, and saves them as an ordered list", ctx do
      entry = element(ctx.lv, "#custom-field-properties-entry")

      render_hook(entry, "select_term_add", %{"field" => "properties", "term" => " nervine "})
      render_hook(entry, "select_term_add", %{"field" => "properties", "term" => "tonic"})
      render_hook(entry, "select_term_add", %{"field" => "properties", "term" => "adaptogen"})

      assert has_element?(ctx.lv, chip(1), "nervine")
      assert has_element?(ctx.lv, chip(2), "adaptogen")
      refute has_element?(ctx.lv, chip(3))

      # Full at max_items: the box goes, and says why.
      refute has_element?(ctx.lv, "#custom-field-properties-entry")
      assert render(ctx.lv) =~ "At the limit of 3 terms."

      ctx.lv
      |> element("#custom-field-properties-terms")
      |> render_hook("select_term_reorder", %{"field" => "properties", "order" => ["2", "0", "1"]})

      ctx.lv |> element("#{chip(2)} button[phx-click=select_term_remove]") |> render_click()

      ctx.lv |> form("#page-editor") |> render_submit()
      assert stored(ctx)["properties"] == ["adaptogen", "tonic"]
    end

    test "removing every term clears the field", ctx do
      ctx.lv |> element("#{chip(0)} button[phx-click=select_term_remove]") |> render_click()
      ctx.lv |> form("#page-editor") |> render_submit()

      refute Map.has_key?(stored(ctx), "properties")
    end
  end

  describe "a :text field" do
    test "a rich one is the TipTap field editor over a hidden input", ctx do
      assert has_element?(ctx.lv, "#cf-rich-uses[phx-hook=RichTextField]")

      assert has_element?(
               ctx.lv,
               ~s(#cf-rich-uses input[type=hidden][name="form[custom_fields][uses]"][data-field-value])
             )

      assert has_element?(ctx.lv, "#cf-rich-uses-editor[phx-update=ignore]")
      refute has_element?(ctx.lv, "textarea#custom-field-uses")
    end

    test "a plain one, and a rich one holding JSON data, keep the textarea", ctx do
      assert has_element?(ctx.lv, "textarea#custom-field-code", "RS-1")
      refute has_element?(ctx.lv, "#cf-rich-code")

      assert has_element?(ctx.lv, "textarea#custom-field-legacy")
      refute has_element?(ctx.lv, "#cf-rich-legacy")
    end

    test "what the field editor writes is saved, sanitized", ctx do
      # The hook writes the hidden input and fires `input`; LiveViewTest won't
      # set a hidden input through `form/3`, so the change is sent as the
      # form's own event would carry it.
      ctx.lv
      |> element("#page-editor")
      |> render_change(%{
        "form" => %{
          "custom_fields" => %{"uses" => ~s(<p>Calms <em>shen</em></p><script>x</script>)}
        }
      })

      ctx.lv |> form("#page-editor") |> render_submit()

      assert stored(ctx)["uses"] == "<p>Calms <em>shen</em></p>x"
    end
  end

  describe "the fields admin" do
    test "offers several terms and an open vocabulary for a select; editing style for text",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/editor/fields")

      lv
      |> form("#new-field-form", %{"field_definition" => %{"field_type" => "select"}})
      |> render_change()

      assert has_element?(lv, "#new-field-multiple-true")
      refute has_element?(lv, "#new-field-multiple-allow-custom")

      lv
      |> form("#new-field-form", %{
        "field_definition" => %{"field_type" => "select", "multiple" => "true"}
      })
      |> render_change()

      assert has_element?(lv, "#new-field-multiple-allow-custom")

      lv
      |> form("#new-field-form", %{"field_definition" => %{"field_type" => "text"}})
      |> render_change()

      assert has_element?(lv, "#new-field-format-rich[checked]")
      assert has_element?(lv, "#new-field-format-plain")
    end
  end
end
