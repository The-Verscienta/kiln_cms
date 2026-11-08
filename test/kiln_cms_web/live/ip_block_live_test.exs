defmodule KilnCMSWeb.IpBlockLiveTest do
  @moduledoc """
  The console screen behind `/editor/ip-blocks` (#2242).

  `async: false`: the self-block and proxy-warning tests set `:trusted_proxies`
  with `Application.put_env/3`, which is VM-global.

  Pinned here: the auth matrix (admin in, everyone else refused), add/remove,
  the tenant boundary on remove (a rule id from another site must not be
  destroyed), and the self-lock-out confirmation step.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  setup do
    org = seed_org()
    on_exit(fn -> KilnCMS.Security.IpBlocklist.bust(org.id) end)
    %{org: org}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/ip-blocks")
    end

    for role <- [:editor, :viewer] do
      test "turns away a #{role} of this very site", %{conn: conn, org: org} do
        user = authed_user(unquote(role))
        grant_tier(user, org, unquote(role))

        assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
                 conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/ip-blocks")
      end
    end

    test "loads for an org admin on their own site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :admin)

      {:ok, _lv, html} = conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/ip-blocks")

      assert html =~ "Blocked addresses"
      assert html =~ "Nothing is blocked."
      assert html =~ "Static files and uploaded media"
    end

    test "an admin of another site is turned away", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, seed_org(), :admin)

      assert {:error, {:redirect, %{to: "/access-denied?needs=admin"}}} =
               conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/ip-blocks")
    end
  end

  describe "add and remove" do
    test "adds a rule with a note and an expiry, then removes it", ctx do
      {lv, _admin} = mount_as_admin(ctx)
      expires = DateTime.utc_now() |> DateTime.add(86_400) |> Calendar.strftime("%Y-%m-%dT%H:%M")

      html =
        lv
        |> form("#ip-block-form",
          rule: %{cidr: "203.0.113.0/24", note: "scraper", expires_at: expires}
        )
        |> render_submit()

      assert html =~ "Address blocked."
      assert html =~ "203.0.113.0/24"
      assert html =~ "scraper"

      [rule] = rules(ctx.org)
      assert rule.note == "scraper"
      assert %DateTime{} = rule.expires_at

      html = lv |> element("#ip-block-#{rule.id} button", "Remove") |> render_click()

      assert html =~ "Block removed."
      assert rules(ctx.org) == []
    end

    test "explains a rule the scanner guard added, and only that one (#2253)", ctx do
      {lv, _admin} = mount_as_admin(ctx)

      for {cidr, note} <- [
            {"203.0.113.7/32", KilnCMS.Security.ScannerGuard.note()},
            {"198.51.100.0/24", "scraper"}
          ] do
        lv |> form("#ip-block-form", rule: %{cidr: cidr, note: note}) |> render_submit()
      end

      [automatic, manual] =
        rules(ctx.org) |> Enum.sort_by(&(&1.note != KilnCMS.Security.ScannerGuard.note()))

      html = render(lv)
      hint = "Added automatically after repeated 404s"

      assert lv |> element("#ip-block-#{automatic.id}") |> render() =~ hint
      refute lv |> element("#ip-block-#{manual.id}") |> render() =~ hint
      assert html =~ hint
    end

    test "a malformed range is reported and nothing is stored", ctx do
      {lv, _admin} = mount_as_admin(ctx)

      lv |> form("#ip-block-form", rule: %{cidr: "not-an-ip"}) |> render_submit()

      assert rules(ctx.org) == []
      refute render(lv) =~ "Address blocked."
    end

    test "validation messages are shown in the console language", ctx do
      {lv, _admin} = mount_as_admin(ctx)

      assert lv |> form("#ip-block-form", rule: %{cidr: "0.0.0.0/0"}) |> render_submit() =~
               "That range is too broad"

      assert lv |> form("#ip-block-form", rule: %{cidr: "127.0.0.1"}) |> render_submit() =~
               "must not include loopback"

      conn = ctx.conn |> org_conn(ctx.org) |> log_in(authed_user(:admin))
      conn = Plug.Conn.put_session(conn, "locale", "fr")
      {:ok, fr, _html} = live(conn, ~p"/editor/ip-blocks")

      html = fr |> form("#ip-block-form", rule: %{cidr: "0.0.0.0/0"}) |> render_submit()

      assert html =~ "trop large"
      refute html =~ "too broad"
    end

    test "an unparseable expiry is refused before anything is stored", ctx do
      {lv, _admin} = mount_as_admin(ctx)

      html =
        lv
        |> form("#ip-block-form", rule: %{cidr: "203.0.113.9", expires_at: "tomorrow"})
        |> render_submit()

      assert html =~ "The expiry is not a valid date and time."
      assert rules(ctx.org) == []
    end

    test "lists only this site's rules", ctx do
      other = seed_org()
      seed_rule(other, "198.51.100.7")
      seed_rule(ctx.org, "203.0.113.7")

      {_lv, html} = mount_html(ctx)

      assert html =~ "203.0.113.7"
      refute html =~ "198.51.100.7"
    end
  end

  describe "tenant isolation" do
    test "cannot remove another site's rule by id", ctx do
      other = seed_org()
      foreign = seed_rule(other, "198.51.100.7")
      {lv, _admin} = mount_as_admin(ctx)

      # The id is not in this page's list; a hand-crafted event still must not
      # reach another tenant's row.
      html = render_click(lv, "remove", %{"id" => foreign.id})

      assert html =~ "That block no longer exists."
      assert [%{id: id}] = rules(other)
      assert id == foreign.id
    end
  end

  describe "authorization is re-checked on the event" do
    test "an admin demoted after mounting cannot add or remove", ctx do
      user = authed_user(:editor)
      membership = grant_tier(user, ctx.org, :admin)
      rule = seed_rule(ctx.org, "203.0.113.7")

      {:ok, lv, _html} =
        ctx.conn |> org_conn(ctx.org) |> log_in(user) |> live(~p"/editor/ip-blocks")

      Ash.Seed.update!(membership, %{role: :editor})

      html = lv |> form("#ip-block-form", rule: %{cidr: "203.0.113.99"}) |> render_submit()
      assert html =~ "don&#39;t have permission"

      html = render_click(lv, "remove", %{"id" => rule.id})
      assert html =~ "don&#39;t have permission" or html =~ "no longer exists"

      assert [%{cidr: "203.0.113.7"}] = rules(ctx.org)
    end
  end

  describe "self-block confirmation" do
    setup do
      previous = Application.get_env(:kiln_cms, :trusted_proxies)
      Application.put_env(:kiln_cms, :trusted_proxies, ["127.0.0.0/8"])

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:kiln_cms, :trusted_proxies)
          prev -> Application.put_env(:kiln_cms, :trusted_proxies, prev)
        end
      end)
    end

    test "a range containing the admin's own address asks first, then adds on confirm", ctx do
      {lv, _admin} = mount_as_admin(ctx, "203.0.113.9")

      html = lv |> form("#ip-block-form", rule: %{cidr: "203.0.113.0/24"}) |> render_submit()

      assert html =~ "may lock you out"
      assert html =~ "203.0.113.9"
      assert rules(ctx.org) == []

      html = lv |> element("#ip-block-confirm") |> render_click()

      assert html =~ "Address blocked."
      refute html =~ "may lock you out"
      assert [%{cidr: "203.0.113.0/24"}] = rules(ctx.org)
    end

    test "cancelling stores nothing", ctx do
      {lv, _admin} = mount_as_admin(ctx, "203.0.113.9")
      lv |> form("#ip-block-form", rule: %{cidr: "203.0.113.9"}) |> render_submit()

      html = lv |> element("#ip-block-cancel") |> render_click()

      refute html =~ "may lock you out"
      assert rules(ctx.org) == []
    end

    test "a range elsewhere is added without a prompt", ctx do
      {lv, _admin} = mount_as_admin(ctx, "203.0.113.9")

      html = lv |> form("#ip-block-form", rule: %{cidr: "198.51.100.0/24"}) |> render_submit()

      refute html =~ "may lock you out"
      assert html =~ "Address blocked."
      assert [%{cidr: "198.51.100.0/24"}] = rules(ctx.org)
    end

    test "a confirm with nothing pending is ignored", ctx do
      {lv, _admin} = mount_as_admin(ctx, "203.0.113.9")

      render_click(lv, "confirm_self_block", %{})

      assert rules(ctx.org) == []
    end
  end

  describe "untrusted forwarding warning" do
    test "shows when a forwarding header arrives and no proxy is trusted", ctx do
      previous = Application.get_env(:kiln_cms, :trusted_proxies)
      Application.delete_env(:kiln_cms, :trusted_proxies)

      on_exit(fn ->
        if previous, do: Application.put_env(:kiln_cms, :trusted_proxies, previous)
      end)

      {_lv, html} = mount_html(ctx, "203.0.113.9")

      assert html =~ "Visitor addresses may be your proxy"
    end

    test "is absent without a forwarding header", ctx do
      {_lv, html} = mount_html(ctx)

      refute html =~ "Visitor addresses may be your proxy"
    end
  end

  defp mount_html(ctx, forwarded_for \\ nil) do
    {lv, _admin} = mount_as_admin(ctx, forwarded_for)
    {lv, render(lv)}
  end

  defp mount_as_admin(%{conn: conn, org: org}, forwarded_for \\ nil) do
    admin = authed_user(:admin)
    conn = conn |> org_conn(org) |> log_in(admin)

    conn =
      if forwarded_for,
        do: Plug.Conn.put_req_header(conn, "x-forwarded-for", forwarded_for),
        else: conn

    {:ok, lv, _html} = live(conn, ~p"/editor/ip-blocks")
    {lv, admin}
  end

  defp rules(org), do: CMS.list_ip_block_rules!(tenant: org, authorize?: false)

  defp seed_rule(org, cidr) do
    Ash.Seed.seed!(CMS.IpBlockRule, %{cidr: cidr, org_id: org.id})
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Block Site",
      slug: "ipblocklive-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "ipblocklive-#{role}-#{System.unique_integer([:positive])}@example.com"

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
end
