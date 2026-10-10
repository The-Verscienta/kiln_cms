defmodule KilnCMSWeb.PluginFieldHookTest do
  @moduledoc """
  Plugin field types with a client hook (#1918): the content editor wraps the
  field in the hook's element, and relays the hook's `"kiln:field_event"` to
  the type's `handle_input_event/3` in a task, answering with a
  `"kiln:field_reply"` push event. The fixture plugin's `Lookup` type
  provides both halves.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"
  @hook "KilnCMS.FixturePlugin.FieldTypes.Lookup.Suggest"

  defp authed_admin do
    email = "pfh-#{System.unique_integer([:positive])}@example.com"

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

  defp open_editor(conn, fields) do
    admin = authed_admin()

    for {name, type} <- fields do
      CMS.create_field_definition!(
        %{content_type: :page, name: name, label: String.capitalize(name), field_type: type},
        actor: admin
      )
    end

    page =
      CMS.create_page!(
        %{title: "Hooked page", slug: "pfh-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(admin)
    |> live(~p"/editor/content/page/#{page.id}")
  end

  defp field_event(lv, field, event, params \\ %{}, ref \\ 1) do
    render_hook(lv, "kiln:field_event", %{
      "field" => field,
      "event" => event,
      "params" => params,
      "ref" => ref
    })

    render_async(lv, 2_000)
  end

  test "the editor wraps a hooked field in the hook's element", %{conn: conn} do
    {:ok, lv, _html} = open_editor(conn, [{"addr", :lookup}])

    wrapper = lv |> element("#cf-hook-addr") |> render()

    assert wrapper =~ ~s(phx-hook="#{@hook}")
    assert wrapper =~ ~s(data-field="addr")
    assert wrapper =~ ~s(data-config="{&quot;min_chars&quot;:3}")
    # The plain input still lives inside, named into the form as before.
    assert has_element?(
             lv,
             "#cf-hook-addr input#custom-field-addr[name$='[custom_fields][addr]']"
           )
  end

  test "a field type without a hook renders no wrapper", %{conn: conn} do
    {:ok, lv, _html} = open_editor(conn, [{"stars", :rating}])

    assert has_element?(lv, "input#custom-field-stars")
    refute has_element?(lv, "#cf-hook-stars")
  end

  test "an input_hook/1 that raises drops the hook, not the field", %{conn: conn} do
    {:ok, lv, _html} = open_editor(conn, [{"explode_hook", :lookup}])

    assert has_element?(lv, "input#custom-field-explode_hook")
    refute has_element?(lv, "#cf-hook-explode_hook")
  end

  test "a hook's event is answered with the callback's reply", %{conn: conn} do
    {:ok, lv, _html} = open_editor(conn, [{"addr", :lookup}])

    field_event(lv, "addr", "suggest", %{"q" => "Main"}, 7)

    assert_push_event(lv, "kiln:field_reply", %{
      field: "addr",
      ref: 7,
      reply: %{suggestions: ["Main Street"], field: "addr"}
    })
  end

  test "an {:error, message} return reaches the hook as its error", %{conn: conn} do
    {:ok, lv, _html} = open_editor(conn, [{"addr", :lookup}])

    field_event(lv, "addr", "nothing")

    assert_push_event(lv, "kiln:field_reply", %{field: "addr", ref: 1, error: "no match"})
  end

  test "a raising or malformed callback answers a generic error and keeps the editor",
       %{conn: conn} do
    {:ok, lv, _html} = open_editor(conn, [{"addr", :lookup}])

    ExUnit.CaptureLog.capture_log(fn ->
      field_event(lv, "addr", "boom", %{}, 1)
      field_event(lv, "addr", "odd", %{}, 2)
    end)

    assert_push_event(lv, "kiln:field_reply", %{field: "addr", ref: 1, error: "failed"})
    assert_push_event(lv, "kiln:field_reply", %{field: "addr", ref: 2, error: "failed"})
    assert render(lv) =~ "Hooked page"
  end

  test "only the record's own fields with a callback are reachable", %{conn: conn} do
    {:ok, lv, _html} = open_editor(conn, [{"addr", :lookup}, {"stars", :rating}])

    # Not a field of this record at all.
    field_event(lv, "elsewhere", "suggest", %{"q" => "x"}, 1)
    assert_push_event(lv, "kiln:field_reply", %{field: "elsewhere", ref: 1, error: "unhandled"})

    # A real field whose type declares no handle_input_event/3.
    field_event(lv, "stars", "suggest", %{"q" => "x"}, 2)
    assert_push_event(lv, "kiln:field_reply", %{field: "stars", ref: 2, error: "unhandled"})
  end

  test "a newer event for the field cancels the one still running", %{conn: conn} do
    {:ok, lv, _html} = open_editor(conn, [{"addr", :lookup}])
    Process.register(self(), :lookup_fixture_slow)

    render_hook(lv, "kiln:field_event", %{"field" => "addr", "event" => "slow", "ref" => 1})
    assert_receive {:slow_started, slow}
    monitor = Process.monitor(slow)

    field_event(lv, "addr", "suggest", %{"q" => "Elm"}, 2)

    assert_receive {:DOWN, ^monitor, :process, ^slow, _reason}
    assert_push_event(lv, "kiln:field_reply", %{field: "addr", ref: 2, reply: %{}})
    refute_push_event(lv, "kiln:field_reply", %{ref: 1})
  end
end
