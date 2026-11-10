defmodule KilnCMSWeb.AccessDeniedTest do
  @moduledoc """
  #2143: a console guard sends someone who lacks the role a page needs to a
  persistent `/access-denied` page, never to `/` with a toast.

  The route enumeration is the behavioural guard. It reads the router, so a new
  admin or editor route (a plugin's included) is covered without anyone editing
  this file, and a LiveView that went back to flashing and redirecting home
  would fail here whichever file it lives in.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.AccessDenied

  @moduletag :capture_log

  @password "password123456"

  defp user(role) do
    email = "denied-#{role}-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Every LiveView route in `session`, with path params filled in. The guard
  # runs before mount, so the values only have to be well-formed.
  defp live_paths(session) do
    for %{plug: Phoenix.LiveView.Plug, path: path, metadata: %{phoenix_live_view: lv}} <-
          Phoenix.Router.routes(KilnCMSWeb.Router),
        elem(lv, 3).name == session do
      path
      |> String.split("/")
      |> Enum.map_join("/", fn
        ":id" -> Ecto.UUID.generate()
        ":" <> _param -> "x"
        segment -> segment
      end)
    end
  end

  describe "every editor-session route" do
    test "the enumeration finds the routes it is meant to guard" do
      paths = live_paths(:editor_routes)

      assert "/editor" in paths
      assert "/editor/inbox" in paths
      assert "/editor/fixture" not in paths
      assert length(paths) > 20
    end

    test "sends a viewer to the access-denied page naming the editor role", %{conn: conn} do
      conn = log_in(conn, user(:viewer))

      for path <- live_paths(:editor_routes) do
        assert {:error, {:redirect, %{to: to} = redirect}} = live(conn, path),
               "viewer on #{path} was not redirected"

        assert to == AccessDenied.path(:editor), "viewer on #{path} went to #{to}"
        assert redirect.flash == %{}, "#{path} still flashes"
      end
    end

    test "leaves a signed-out visitor on the sign-in redirect", %{conn: conn} do
      for path <- live_paths(:editor_routes) do
        assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, path),
               "anonymous on #{path} did not go to sign-in"
      end
    end
  end

  describe "every admin-session route" do
    test "the enumeration finds the routes it is meant to guard, plugins included" do
      paths = live_paths(:admin_routes)

      assert "/editor/webhooks" in paths
      assert "/editor/billing" in paths
      assert "/editor/fixture" in paths
      assert length(paths) > 30
    end

    test "sends an editor to the access-denied page naming the admin role", %{conn: conn} do
      conn = log_in(conn, user(:editor))

      for path <- live_paths(:admin_routes) do
        assert {:error, {:redirect, %{to: to} = redirect}} = live(conn, path),
               "editor on #{path} was not redirected"

        assert to == AccessDenied.path(:admin), "editor on #{path} went to #{to}"
        assert redirect.flash == %{}, "#{path} still flashes"
      end
    end

    test "sends a viewer to the same page", %{conn: conn} do
      conn = log_in(conn, user(:viewer))

      for path <- live_paths(:admin_routes) do
        assert {:error, {:redirect, %{to: to}}} = live(conn, path)
        assert to == AccessDenied.path(:admin), "viewer on #{path} went to #{to}"
      end
    end

    test "leaves a signed-out visitor on the sign-in redirect", %{conn: conn} do
      for path <- live_paths(:admin_routes) do
        assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, path),
               "anonymous on #{path} did not go to sign-in"
      end
    end
  end

  describe "GET /access-denied" do
    test "answers 403 and names the editor role for a viewer", %{conn: conn} do
      conn = conn |> log_in(user(:viewer)) |> get(AccessDenied.path(:editor))
      html = html_response(conn, 403)

      assert html =~ "This page needs editor access"
      assert html =~ "You are signed in as viewer"
      assert html =~ "ask an admin of"
      assert html =~ ~s(id="access-denied-account")
      refute html =~ ~s(id="access-denied-sign-in")
    end

    test "says a signed-in account with no role on this site has none (#2372)", %{conn: conn} do
      # A member of another site only: no tier on the default org this request
      # runs under, so it must not be told it is a viewer here.
      account = user(:editor)

      other =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Elsewhere #{System.unique_integer([:positive])}",
          slug: "elsewhere-#{System.unique_integer([:positive])}"
        })

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: account.id,
        organization_id: other.id,
        role: :editor
      })

      assert KilnCMS.Accounts.Scoping.effective_tier(account, KilnCMS.Accounts.default_org_id()) ==
               :none

      html = conn |> log_in(account) |> get(AccessDenied.path(:editor)) |> html_response(403)

      assert html =~ "You are signed in, but your account has no role on"
      assert html =~ "give your account a role"
      assert html =~ ~s(id="access-denied-sign-out")
      refute html =~ "You are signed in as"
      refute html =~ ~s(id="access-denied-account")
      refute html =~ ~s(id="access-denied-console")
      refute html =~ ~s(id="access-denied-sign-in")
    end

    test "names the admin role for an editor and links back to the console", %{conn: conn} do
      html = conn |> log_in(user(:editor)) |> get(AccessDenied.path(:admin)) |> html_response(403)

      assert html =~ "This page needs admin access"
      assert html =~ "You are signed in as editor"
      assert html =~ ~s(id="access-denied-console")
    end

    test "names the platform admin for an instance-wide page", %{conn: conn} do
      html =
        conn |> log_in(user(:editor)) |> get(AccessDenied.path(:platform)) |> html_response(403)

      assert html =~ "This page needs platform admin access"
      assert html =~ "administers this installation"
    end

    test "offers sign-in to a signed-out visitor", %{conn: conn} do
      html = conn |> get(AccessDenied.path(:admin)) |> html_response(403)

      assert html =~ "You are not signed in"
      assert html =~ ~s(id="access-denied-sign-in")
      refute html =~ "You are signed in as"
    end

    test "is noindex in the header and the markup", %{conn: conn} do
      conn = get(conn, AccessDenied.path(:editor))

      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert html_response(conn, 403) =~ ~s(<meta name="robots" content="noindex")
    end

    test "falls back to generic copy for a missing or unknown needs value", %{conn: conn} do
      for path <- ["/access-denied", "/access-denied?needs=superuser", "/access-denied?needs[]=x"] do
        html = conn |> get(path) |> html_response(403)

        assert html =~ "You don&#39;t have access to this page"
        refute html =~ "This page needs"
      end
    end

    test "never reflects the query", %{conn: conn} do
      payload = "<script>alert(1)</script>"

      html =
        conn
        |> get("/access-denied?needs=#{URI.encode_www_form(payload)}&from=//evil.example/x")
        |> html_response(403)

      refute html =~ "alert(1)"
      refute html =~ "evil.example"
    end

    test "keeps the viewer's own role from the session, not the query", %{conn: conn} do
      html =
        conn
        |> log_in(user(:viewer))
        |> get("/access-denied?needs=editor&role=admin")
        |> html_response(403)

      assert html =~ "You are signed in as viewer"
    end
  end

  describe "the paths" do
    test "path/1 builds the whitelisted URLs and parse/1 reads them back" do
      for role <- [:editor, :admin, :platform] do
        assert AccessDenied.path(role) == "/access-denied?needs=#{role}"
        assert AccessDenied.parse(Atom.to_string(role)) == role
      end

      assert AccessDenied.parse("root") == nil
      assert AccessDenied.parse(nil) == nil
      assert AccessDenied.parse(["editor"]) == nil
    end

    test "the slug is reserved so a page can't be shadowed by it" do
      assert "access-denied" in KilnCMS.CMS.ContentTypes.reserved_path_segments()
    end
  end
end
