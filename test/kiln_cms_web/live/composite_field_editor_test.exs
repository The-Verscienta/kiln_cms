defmodule KilnCMSWeb.CompositeFieldEditorTest do
  @moduledoc """
  The content editor's widgets for the built-in composite field types (#2278):
  the range and link part inputs (with the link's blank-first target select),
  and the key/value textarea. Covers the write path an editor takes: an
  untouched widget saves nothing, a hostile address is refused with the typed
  text kept, and a good value round-trips.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "cfe-#{System.unique_integer([:positive])}@example.com"

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

  defp editor(conn, admin, fields) do
    for {name, type} <- [
          {"band", :range},
          {"specs", :key_value},
          {"cfe_source", :link},
          {"venue", :address}
        ] do
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: name,
          label: String.capitalize(String.replace_prefix(name, "cfe_", "")),
          field_type: type
        },
        actor: admin
      )
    end

    page =
      CMS.create_page!(
        %{title: "Cmp", slug: "cfe-#{System.unique_integer([:positive])}", custom_fields: fields},
        actor: admin
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    {:ok, lv, html} = live(conn, ~p"/editor/content/page/#{page.id}")
    {lv, html, page}
  end

  defp change(lv, fields) do
    lv
    |> form("#page-editor", %{"form" => %{"custom_fields" => fields}})
    |> render_change()
  end

  test "the widgets render: range parts, link parts with a blank-first select, a textarea" do
    {_lv, html, _page} =
      editor(
        Phoenix.ConnTest.build_conn(),
        authed_admin(),
        %{
          "band" => %{"min" => 5, "max" => 9},
          "specs" => [%{"key" => "Weight", "value" => "2 kg"}],
          "cfe_source" => %{"url" => "/about", "target" => "_blank"}
        }
      )

    assert html =~ ~r/<input[^>]*name="form\[custom_fields\]\[band\]\[min\]"[^>]*value="5"/ or
             html =~ ~r/<input[^>]*value="5"[^>]*name="form\[custom_fields\]\[band\]\[min\]"/

    assert html =~ ~r/<textarea[^>]*id="custom-field-specs"/
    assert html =~ "Weight=2 kg"
    assert html =~ ~r/<select[^>]*name="form\[custom_fields\]\[cfe_source\]\[target\]"/
    assert html =~ ~r/<option[^>]*value="_blank"[^>]*selected/
    assert html =~ ~r/<option[^>]*value=""/
  end

  test "range and link parts carry translatable help text wired by aria-describedby" do
    {_lv, html, _page} = editor(Phoenix.ConnTest.build_conn(), authed_admin(), %{})

    assert html =~ ~r/id="custom-field-band-max-help"[^>]*>\s*The same kind as From/
    assert html =~ ~r/aria-describedby="custom-field-band-max-help"/
    assert html =~ ~r/id="custom-field-cfe_source-rel-help"[^>]*>\s*Space-separated: noopener/
    assert html =~ ~r/aria-describedby="custom-field-cfe_source-rel-help"/
  end

  test "a failed save shows the message and keeps what was typed", %{conn: conn} do
    {lv, _html, _page} = editor(conn, authed_admin(), %{})

    html =
      change(lv, %{
        "specs" => "no equals sign",
        "cfe_source" => %{"url" => "javascript:alert(1)", "label" => "Click"},
        "band" => %{"min" => "9", "max" => "1"}
      })

    assert html =~ "each line must be key=value"
    assert html =~ "no equals sign"
    assert html =~ "address must be an http(s) URL"
    assert html =~ "javascript:alert(1)"
    assert html =~ "the minimum must not be greater than the maximum"
  end

  test "the address widget: a country select over every country, then the text parts" do
    {_lv, html, _page} =
      editor(Phoenix.ConnTest.build_conn(), authed_admin(), %{
        "venue" => %{"country" => "GB", "locality" => "London", "postal_code" => "SW1A 1AA"}
      })

    assert html =~ ~r/<select[^>]*name="form\[custom_fields\]\[venue\]\[country\]"/
    assert html =~ ~r/<option[^>]*value="GB"[^>]*selected/
    assert html =~ ~r/<option[^>]*value="JP"/
    assert html =~ ~r/<option[^>]*value=""/
    assert length(Regex.scan(~r/<option /, html)) > 249

    assert html =~
             ~r/<input[^>]*name="form\[custom_fields\]\[venue\]\[locality\]"[^>]*value="London"/ or
             html =~
               ~r/<input[^>]*value="London"[^>]*name="form\[custom_fields\]\[venue\]\[locality\]"/
  end

  test "an address saves normalised, refuses a bad postal code, and an untouched one saves nothing",
       %{conn: conn} do
    admin = authed_admin()
    {lv, _html, page} = editor(conn, admin, %{})

    lv |> form("#page-editor") |> render_submit()
    saved = CMS.get_page!(page.id, actor: admin)
    refute Map.has_key?(saved.custom_fields, "venue")

    html =
      change(lv, %{"venue" => %{"country" => "US", "postal_code" => "ABC"}})

    assert html =~ "postal code is not a valid United States postal code"
    assert html =~ "ABC"

    lv
    |> form("#page-editor", %{
      "form" => %{
        "custom_fields" => %{
          "venue" => %{"country" => "CA", "locality" => "Ottawa", "postal_code" => "k1a0b1"}
        }
      }
    })
    |> render_submit()

    saved = CMS.get_page!(page.id, actor: admin)

    assert saved.custom_fields["venue"] ==
             %{"country" => "CA", "locality" => "Ottawa", "postal_code" => "K1A 0B1"}
  end

  test "an untouched editor saves none of the three", %{conn: conn} do
    admin = authed_admin()
    {lv, _html, page} = editor(conn, admin, %{})

    lv |> form("#page-editor") |> render_submit()

    saved = CMS.get_page!(page.id, actor: admin)
    for name <- ~w(band specs cfe_source), do: refute(Map.has_key?(saved.custom_fields, name))
  end

  test "good values are saved normalised, and clearing them removes the keys", %{conn: conn} do
    admin = authed_admin()
    {lv, _html, page} = editor(conn, admin, %{})

    lv
    |> form("#page-editor", %{
      "form" => %{
        "custom_fields" => %{
          "band" => %{"min" => "2026-01-01", "max" => ""},
          "specs" => "Weight = 2 kg\nColour=red",
          "cfe_source" => %{"url" => " https://example.com ", "target" => "_blank"}
        }
      }
    })
    |> render_submit()

    saved = CMS.get_page!(page.id, actor: admin)
    assert saved.custom_fields["band"] == %{"min" => "2026-01-01"}

    assert [%{"key" => "Weight", "value" => "2 kg"}, %{"key" => "Colour"}] =
             saved.custom_fields["specs"]

    assert saved.custom_fields["cfe_source"] == %{
             "url" => "https://example.com",
             "target" => "_blank",
             "rel" => "noopener noreferrer"
           }

    lv
    |> form("#page-editor", %{
      "form" => %{
        "custom_fields" => %{
          "band" => %{"min" => "", "max" => ""},
          "specs" => "",
          "cfe_source" => %{"url" => "", "label" => "", "target" => "", "rel" => ""}
        }
      }
    })
    |> render_submit()

    cleared = CMS.get_page!(page.id, actor: admin)
    for name <- ~w(band specs cfe_source), do: refute(Map.has_key?(cleared.custom_fields, name))
  end
end
