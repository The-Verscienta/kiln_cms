defmodule KilnCMSWeb.AuthPageOnMountTest do
  @moduledoc """
  Every hook the router lists for an auth page actually runs on it.

  AshAuthentication's route macros (`sign_in_route`, `reset_route`,
  `sign_out_route`, `confirm_route`, `magic_sign_in_route`) build the
  `live_session`'s `on_mount` list and then `Enum.uniq_by/2` it **by module**,
  so a second `{KilnCMSWeb.LiveUserAuth, _}` entry is dropped without a word.
  The routes listed `:restore_locale` first, and it was the only one that ran:
  `:assign_current_org` never did, so `:current_org` was absent, the auth layout
  failed closed to stock branding on every host (a tenant's sign-in page drew
  "KilnCMS" instead of its own name and logo), and the socket's `host_uri` was
  never vouched (#687) before `KilnCMSWeb.SignInLive` handed a patch URI to the
  library.

  The fix routes each of them through a single `LiveUserAuth` entry that names
  its steps. Two halves are asserted: the router shape, for every auth page at
  once, and the rendered result, per page.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import KilnCMS.OrgFixtures

  alias KilnCMSWeb.LiveUserAuth

  defp branded_org(name) do
    o = org("authmount")
    Ash.Seed.seed!(KilnCMS.CMS.SiteBranding, %{org_id: o.id, site_name: name})
    KilnCMS.Cache.bust_branding(o.id)
    o
  end

  # Discovered from the router by live_session name, as `AuthTitlesTest` does:
  # `:auth_*` is what the library's macros declare, so a page added by an
  # upstream release is covered without editing this list.
  defp auth_live_routes do
    for route <- KilnCMSWeb.Router.__routes__(),
        {_view, _action, _opts, %{name: name} = session} <-
          [route.metadata[:phoenix_live_view]],
        to_string(name) =~ ~r/^auth_/ do
      {route.path, Enum.map(session.extra[:on_mount] || [], & &1.id)}
    end
  end

  describe "the router" do
    test "every auth live session keeps :restore_locale and :assign_current_org" do
      routes = auth_live_routes()

      # sign-in, register, reset (one view), password-reset, confirm, magic
      # link, sign-out — a filter that matched nothing would make this vacuous.
      assert length(routes) >= 7

      for {path, hooks} <- routes do
        steps =
          Enum.flat_map(hooks, fn
            {LiveUserAuth, steps} when is_list(steps) -> steps
            {LiveUserAuth, step} -> [step]
            _other -> []
          end)

        assert :restore_locale in steps and :assign_current_org in steps,
               "#{path} runs only #{inspect(steps)} from LiveUserAuth — its route macro " <>
                 "de-duplicates on_mount by module, so list LiveUserAuth once, as " <>
                 "{LiveUserAuth, [step, ...]}. Hooks: #{inspect(hooks)}"
      end
    end

    test "the sign-in session keeps :live_no_user" do
      {_path, hooks} = Enum.find(auth_live_routes(), fn {path, _} -> path == "/sign-in" end)

      assert {LiveUserAuth, [:restore_locale, :assign_current_org, :live_no_user]} in hooks
    end
  end

  describe "a tenant host's auth pages carry its branding" do
    setup %{conn: conn} do
      o = branded_org("Acme Docs")
      %{org: o, conn: org_conn(conn, o)}
    end

    for path <- [
          "/sign-in",
          "/register",
          "/reset",
          "/password-reset/not-a-real-token",
          "/confirm_new_user/not-a-real-token",
          "/magic_link/not-a-real-token",
          "/sign-out"
        ] do
      test "#{path}", %{conn: conn, org: o} do
        {:ok, lv, _html} = live(conn, unquote(path))

        assigns = :sys.get_state(lv.pid).socket.assigns
        assert assigns.current_org.id == o.id

        # The banner `Layouts.auth/1` draws, on the connected render. The
        # document <title> is the root layout's and carries the name either
        # way, which is why a title assertion never caught this.
        assert render(lv) =~ "Acme Docs"
      end
    end

    test "/sign-in still assigns no user and a nil scope for a visitor", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sign-in")

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert Map.has_key?(assigns, :current_user) and is_nil(assigns.current_user)
      assert Map.has_key?(assigns, :current_scope) and is_nil(assigns.current_scope)
    end
  end

  describe "{LiveUserAuth, [step, ...]}" do
    test "halts at the first step that halts" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}},
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      # `:live_user_required` halts with no user; `:restore_locale` would
      # assign `:locale` if the chain went on past it.
      assert {:halt, halted} =
               LiveUserAuth.on_mount([:live_user_required, :restore_locale], %{}, %{}, socket)

      refute Map.has_key?(halted.assigns, :locale)
    end
  end
end
