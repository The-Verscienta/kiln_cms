defmodule KilnCMSWeb.EditorTelemetryTest do
  @moduledoc """
  The content editor emits `[:kiln_cms, :editor, …]` telemetry for save,
  autosave and publish (issue #41) so the editor hot path can be profiled in
  LiveDashboard / Prometheus. Each test attaches a handler and asserts the event
  fires with a duration measurement and `kind`/`result` metadata.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp authed_user(role) do
    email = "tele-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp draft_page(attrs \\ %{}) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{title: "A page", slug: "tele-#{System.unique_integer([:positive])}", state: :draft},
        attrs
      )
    )
  end

  # Attach a handler that forwards a single `[:kiln_cms, :editor, event]` to this
  # process, and detach when the test ends.
  defp listen(event) do
    test_pid = self()
    handler_id = "test-editor-#{event}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kiln_cms, :editor, event],
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "explicit Save emits a :save event", %{conn: conn} do
    listen(:save)
    page = draft_page(%{title: "Old"})

    {:ok, lv, _html} =
      conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

    lv |> form("#page-editor", form: %{title: "Saved title"}) |> render_submit()

    assert_receive {:telemetry, [:kiln_cms, :editor, :save], measurements, metadata}
    assert is_integer(measurements.duration)
    assert measurements.count == 1
    assert metadata.kind == :page
    assert metadata.result == :ok
  end

  test "debounced autosave emits an :autosave event", %{conn: conn} do
    listen(:autosave)
    page = draft_page(%{title: "Old"})

    {:ok, lv, _html} =
      conn |> log_in(authed_user(:editor)) |> live(~p"/editor/pages/#{page.id}")

    lv |> form("#page-editor", form: %{title: "Autosaved"}) |> render_change()
    send(lv.pid, :autosave)
    render(lv)

    assert_receive {:telemetry, [:kiln_cms, :editor, :autosave], measurements, metadata}
    assert is_integer(measurements.duration)
    assert metadata.kind == :page
    assert metadata.result == :ok
  end

  test "publishing emits a :publish event", %{conn: conn} do
    listen(:publish)
    page = draft_page()

    {:ok, lv, _html} =
      conn |> log_in(authed_user(:admin)) |> live(~p"/editor/pages/#{page.id}")

    lv |> element("button", "Publish") |> render_click()

    assert_receive {:telemetry, [:kiln_cms, :editor, :publish], measurements, metadata}
    assert is_integer(measurements.duration)
    assert metadata.kind == :page
    assert metadata.result == :ok
  end
end
