defmodule KilnCMSWeb.SecurityNoticesNoNetworkTest do
  @moduledoc """
  #2522's promise: the security notices feed is asked only when a platform
  admin opens a page that reads it (System, Security posture). A public page,
  the public API, the sign-in page and an editor's console page must not
  reach it, not even through a background warmer.

  The stub reports every request with `send/2` rather than failing the test
  itself: the fetch runs in a task whose body turns any exception into an
  answer, so an assertion raised there would be swallowed. A request from a
  process the stub cannot be found from would crash into a stored
  `{:error, {:crashed, _}}`, which the final `cached/0 == nil` catches.

  `async: false`: the notices cache is `:persistent_term`, the warmers
  node-wide registered names, and the feed switch application env.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import KilnCMS.Test.Eventually, only: [eventually: 1]

  alias Kiln.Plugins.Health
  alias Kiln.SecurityNotices
  alias KilnCMS.Accounts.User

  @moduletag :capture_log
  @password "password123456"

  setup do
    notices = Application.get_env(:kiln_cms, SecurityNotices, [])
    health = Application.get_env(:kiln_cms, Health, [])
    Health.clear_cache()

    # Opted in the way production is: the URL follows the update feed
    # (kilncms.dev's), and the plugin health check is on too.
    Application.put_env(:kiln_cms, SecurityNotices, Keyword.put(notices, :url, nil))
    Application.put_env(:kiln_cms, Health, Keyword.put(health, :enabled, true))

    on_exit(fn ->
      Application.put_env(:kiln_cms, SecurityNotices, notices)
      Application.put_env(:kiln_cms, Health, health)
      Health.clear_cache()
    end)

    test = self()

    for name <- [SecurityNotices, Health] do
      Req.Test.stub(name, fn conn ->
        send(test, {:request, conn.host, conn.request_path})
        Req.Test.json(conn, %{"data" => []})
      end)
    end

    :ok
  end

  defp editor do
    email = "no-network-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
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

  test "public pages, the API, sign-in and an editor's console page ask nothing", %{conn: conn} do
    # The opt-in took: the feed would be asked if anything asked it.
    assert {:ok, _url} = SecurityNotices.url()

    assert conn |> get(~p"/") |> response(200)

    assert build_conn()
           |> put_req_header("accept", "application/vnd.api+json")
           |> get("/api/json/entries/published")
           |> json_response(200)

    assert {:ok, _lv, _html} = live(build_conn(), ~p"/sign-in")

    signed_in =
      build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(editor())

    assert {:ok, lv, _html} = live(signed_in, ~p"/editor")
    render_async(lv, 1000)

    # Anything those requests started in the background has finished.
    eventually(fn ->
      is_nil(Process.whereis(SecurityNotices.warmer_name())) and
        is_nil(Process.whereis(Health.warmer_name()))
    end)

    refute_received {:request, _host, _path}
    assert SecurityNotices.cached() == nil
  end
end
