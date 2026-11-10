defmodule KilnCMSWeb.AdminAllowlistRoutesTest do
  @moduledoc """
  Which routes the admin allowlist gates (#2248), as a fact on each route: its
  `pipe_through`. Pinned so a new route lands inside or outside the gate on
  purpose — a console page left out is a hole in the list, and a delivery route
  pulled in takes a site's public pages away from its visitors.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.AdminAllowlist, as: Gate
  alias KilnCMSWeb.Router
  alias KilnCMSWeb.Surface

  # `/auth` is `auth_routes`: one forward holding every strategy's callbacks
  # (password, magic link, confirmation, the operator's OIDC provider).
  @gated ~w(
    /auth /auth/invite/:invite_token /auth/passkey/options /auth/passkey/verify /auth/site-sso
    /auth/site-sso/callback /auth/unlock/:unlock_token /confirm_new_user/:token /magic_link/:token
    /password-reset/:token /register /reset /setup /sign-in /sign-in/unlock /sign-in/verify
  )

  @gated_api ~w(/api/auth/sign_in /api/auth/sign_in/verify /api/security/posture)

  # Every route, with the `pipe_through` the router matched it to. A pattern
  # that matches an earlier route when read literally is that route's business.
  defp routes do
    for route <- Router.__routes__(),
        verb =
          route.verb
          |> to_string()
          |> String.upcase()
          |> then(&if(&1 == "*", do: "GET", else: &1)),
        %{route: path} = info <- [
          Phoenix.Router.route_info(Router, verb, route.path, "localhost")
        ],
        path == route.path,
        uniq: true do
      %{
        path: path,
        verb: verb,
        pipe_through: info.pipe_through,
        surface: Surface.of(info),
        live_session: live_session(info)
      }
    end
  end

  defp live_session(info) do
    case info[:phoenix_live_view] do
      {_view, _action, _opts, %{name: name}} -> name
      _ -> nil
    end
  end

  defp gated?(route), do: :admin_allowlist in route.pipe_through
  defp gated_api?(route), do: :admin_allowlist_api in route.pipe_through

  test "every console route is gated (but the dev-only tools)" do
    missing =
      for route <- routes(),
          route.surface == :console,
          :browser_dev_tools not in route.pipe_through,
          not gated?(route),
          do: route.path

    assert missing == []
  end

  test "every sign-in route is gated, and signing out is not" do
    for route <- routes(), :browser_auth in route.pipe_through do
      if route.path == "/sign-out",
        do: refute(gated?(route), "/sign-out must stay reachable"),
        else: assert(gated?(route), "#{route.verb} #{route.path} is not gated")
    end
  end

  test "the headless sign-in and the security posture are gated in JSON, and nothing else under /api is" do
    api = for route <- routes(), String.starts_with?(route.path, "/api"), do: route

    assert api |> Enum.filter(&gated_api?/1) |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort() ==
             @gated_api

    refute Enum.any?(api, &gated?/1)
  end

  test "outside the console, exactly /setup and the sign-in family are gated" do
    gated =
      for route <- routes(), route.surface != :console, gated?(route), uniq: true, do: route.path

    assert Enum.sort(gated) == Enum.sort(@gated)
  end

  test "no delivery route is gated but /setup, and no shared route outside sign-in" do
    for route <- routes(), gated?(route) or gated_api?(route) do
      case route.surface do
        :console -> :ok
        :delivery -> assert route.path == "/setup", "#{route.path} is delivery"
        :shared -> assert route.path in (@gated ++ @gated_api), "#{route.path} is shared"
      end
    end
  end

  test "the gate runs before anything else in its pipe_through" do
    for route <- routes(), gated?(route) or gated_api?(route) do
      assert hd(route.pipe_through) in [:admin_allowlist, :admin_allowlist_api],
             "#{route.path}: #{inspect(route.pipe_through)}"
    end
  end

  test "a gated route's live session gates its joins, and no other session does" do
    live = for route <- routes(), route.live_session, do: route

    gated_sessions =
      live |> Enum.filter(&gated?/1) |> Enum.map(& &1.live_session) |> Enum.uniq() |> Enum.sort()

    assert Gate.gated_live_sessions() == gated_sessions

    # A session is all inside the gate or all outside it.
    for route <- live do
      assert gated?(route) == route.live_session in gated_sessions,
             "#{route.path} (#{route.live_session})"
    end
  end
end
