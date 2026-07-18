defmodule KilnCMSWeb.PreviewLiveTest do
  @moduledoc "Multiplayer live preview with presence + cursors (#343)."
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(name) do
    email = "prev-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      name: name,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp conn_for(name) do
    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(authed_user(name))
  end

  defp a_page do
    actor =
      Ash.Seed.seed!(User, %{
        email: "prev-admin-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt(@password),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    CMS.create_page!(
      %{
        title: "Shared Draft",
        slug: "prev-#{System.unique_integer([:positive])}",
        blocks: [%{type: :heading, content: "Together", data: %{"level" => 1}, order: 0}]
      },
      actor: actor
    )
  end

  # Presence/cursor diffs propagate asynchronously; retry the render briefly.
  defp eventually(view, substring, present? \\ true, tries \\ 40) do
    html = render(view)

    cond do
      String.contains?(html, substring) == present? ->
        html

      tries == 0 ->
        flunk("expected #{substring} #{if present?, do: "in", else: "gone from"} render")

      true ->
        Process.sleep(25) && eventually(view, substring, present?, tries - 1)
    end
  end

  test "co-viewers see each other in the presence bar" do
    page = a_page()
    path = ~p"/editor/preview/page/#{page.id}"

    {:ok, alice, _} = live(conn_for("Alice"), path)
    # Alice alone: no "N viewing" count badge yet (the aria-label always says
    # "People viewing", so match the count text specifically).
    refute render(alice) =~ "2 viewing"

    {:ok, bob, _} = live(conn_for("Bob"), path)

    # Bob's join reaches Alice via a presence diff.
    assert eventually(alice, "Bob") =~ "2 viewing"
    assert eventually(bob, "Alice")
  end

  test "a viewer's cursor moves appear on a co-viewer's screen" do
    page = a_page()
    path = ~p"/editor/preview/page/#{page.id}"

    {:ok, alice, _} = live(conn_for("Alice"), path)
    {:ok, bob, _} = live(conn_for("Bob"), path)

    # No remote cursors until someone moves.
    refute render(bob) =~ "remote-cursor"

    render_hook(alice, "cursor", %{"x" => 0.5, "y" => 0.25})

    html = render(bob)
    assert html =~ "remote-cursor"
    assert html =~ "Alice"
    assert html =~ "left:50.0%;top:25.0%"

    # Alice does not render her own cursor.
    refute render(alice) =~ "remote-cursor"
  end

  test "an edge cursor coordinate (JSON integer 0/1) does not crash the render" do
    page = a_page()
    path = ~p"/editor/preview/page/#{page.id}"

    {:ok, alice, _} = live(conn_for("Alice"), path)
    {:ok, bob, _} = live(conn_for("Bob"), path)

    # A cursor exactly at the left/top edge arrives as the integer 0 (JS 0/500);
    # float_to_binary/2 raises on an integer, so this must be handled.
    render_hook(alice, "cursor", %{"x" => 0, "y" => 1})

    html = render(bob)
    assert html =~ "remote-cursor"
    assert html =~ "left:0.0%;top:100.0%"
  end

  test "leaving drops a viewer (and their cursor) for everyone else" do
    page = a_page()
    path = ~p"/editor/preview/page/#{page.id}"

    {:ok, alice, _} = live(conn_for("Alice"), path)
    {:ok, bob, _} = live(conn_for("Bob"), path)

    render_hook(bob, "cursor", %{"x" => 0.1, "y" => 0.1})
    assert render(alice) =~ "remote-cursor"

    # Bob closes his window.
    ref = Process.monitor(bob.pid)
    GenServer.stop(bob.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}

    # Alice sees the presence drop and Bob's cursor removed (via a leave diff).
    html = eventually(alice, "Bob", false)
    refute html =~ "remote-cursor"
    refute html =~ "2 viewing"
  end
end
