defmodule KilnCMSWeb.CodeInjectionLiveTest do
  @moduledoc """
  The console screen behind `/editor/code-injection` (#490).

  `KilnCMS.CodeInjectionTest` covers the resource (hashing, origin validation,
  resolution) and `KilnCMSWeb.CodeInjectionDeliveryTest` covers where the
  snippet renders and under what policy. Neither one mounts this LiveView, so
  the screen that *writes* stored XSS into a site had no test at all — no auth
  matrix, no save, no reset.

  Two things here are this module's own and are not checked anywhere else:

    * **the auth matrix.** The route sits behind the `:live_admin_required`
      hook and the resource behind an org-admin policy, and both resolve the
      tier against the *request's* org. The tests below pin both halves — a
      non-admin turned away at mount, an org admin admitted on their own site —
      because a regression in either one hands script execution on the
      console's origin to whoever holds the lesser role.
    * **`attrs/1`.** The form's strings become the row's values here:
      newline-separated origins become lists and an unchecked box becomes
      `false`. Nothing downstream can restore what this function gets wrong —
      each is mutation-checked.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password1234!"

  setup do
    org = seed_org()
    on_exit(fn -> KilnCMS.Cache.bust_code_injection(org.id) end)
    %{org: org}
  end

  describe "access" do
    test "redirects an anonymous visitor to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/code-injection")
    end

    test "turns away an editor of this very site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_tier(user, org, :editor)

      # A *member* with the editor tier, not merely a stranger: the two reach
      # `effective_tier/2` down different branches, and only this one proves the
      # gate is on the tier rather than on affiliation.
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/code-injection")

      assert flash["error"] =~ "admin access"
    end

    test "turns away a signed-in account with no membership here", %{conn: conn, org: org} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               conn
               |> org_conn(org)
               |> log_in(authed_user(:editor))
               |> live(~p"/editor/code-injection")

      assert flash["error"] =~ "admin access"
    end

    test "turns away an org admin visiting a site they are not an admin of", %{conn: conn} do
      user = authed_user(:editor)
      grant_org_admin(user, seed_org())

      # Admin *somewhere* is not admin *here*: the hook resolves the tier
      # against the request's org, which is the whole reason this page can be
      # org-scoped at all.
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               conn
               |> org_conn(seed_org())
               |> log_in(user)
               |> live(~p"/editor/code-injection")

      assert flash["error"] =~ "admin access"
    end

    test "loads for a platform admin, and says what the page does", %{conn: conn, org: org} do
      {:ok, _lv, html} =
        conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/code-injection")

      assert html =~ "Code injection"
      # The warning is load-bearing UI, not decoration: an admin pasting a
      # vendor snippet has to be told what they are extending.
      assert html =~ "This runs code on your public site."
      assert html =~ "Head HTML"
      assert html =~ "Allowed origins"
    end

    test "loads for an org admin on their own site", %{conn: conn, org: org} do
      user = authed_user(:editor)
      grant_org_admin(user, org)

      {:ok, _lv, html} =
        conn |> org_conn(org) |> log_in(user) |> live(~p"/editor/code-injection")

      assert html =~ "Head HTML"
    end
  end

  describe "saving" do
    test "writes the snippet and its origins for the current site only", ctx do
      other = seed_org()
      on_exit(fn -> KilnCMS.Cache.bust_code_injection(other.id) end)

      lv = mount_as_admin(ctx)

      html =
        save(lv, %{
          head_html: ~s(<script>window.plausible = 1</script>),
          footer_html: "<!-- footer -->",
          script_src: "https://plausible.io\nhttps://cdn.example.com",
          connect_src: "https://plausible.io",
          img_src: "",
          enabled: "true"
        })

      assert html =~ "Code injection saved."

      row = row!(ctx.org)
      assert row.head_html == ~s(<script>window.plausible = 1</script>)
      assert row.footer_html == "<!-- footer -->"
      # One origin per line is what someone pastes; the list is what gets
      # merged into the delivery CSP.
      assert row.script_src == ["https://plausible.io", "https://cdn.example.com"]
      assert row.connect_src == ["https://plausible.io"]
      assert row.img_src == []
      assert row.enabled

      # The other site is untouched — this page configures the site you are on.
      assert {:ok, []} = CMS.list_site_code_injection(tenant: other, authorize?: false)
      refute KilnCMS.CodeInjection.for_org(other.id).head_html
    end

    test "an org admin's save is attributed to them", ctx do
      user = authed_user(:editor)
      grant_org_admin(user, ctx.org)

      {:ok, lv, _html} =
        ctx.conn |> org_conn(ctx.org) |> log_in(user) |> live(~p"/editor/code-injection")

      save(lv, %{head_html: "<!-- theirs -->", enabled: "true"})

      assert row!(ctx.org).head_html == "<!-- theirs -->"
    end

    test "a blank textarea is stored as nothing, not as an empty element", ctx do
      lv = mount_as_admin(ctx)

      save(lv, %{head_html: "<!-- keep -->", footer_html: "   \n  ", enabled: "true"})

      row = row!(ctx.org)
      assert row.head_html == "<!-- keep -->"
      # Behaviour, not attribution: what nils this is Ash's `:string` cast,
      # which trims and refuses the empty string. The LiveView carries no
      # blank-handling of its own — it used to, and the helper was dead. Read
      # this as "an admin who cleared a box gets no empty element on their
      # site", not as covering a line in `attrs/1`.
      assert row.footer_html == nil
    end

    test "an unchecked box stops serving the snippet without discarding it", ctx do
      lv = mount_as_admin(ctx)

      # Phoenix omits an unchecked checkbox from the params entirely, so this is
      # the shape the handler actually receives — and `enabled` has to come back
      # false from it rather than defaulting to true.
      save(lv, %{head_html: "<!-- paused -->", enabled: "false"})

      row = row!(ctx.org)
      refute row.enabled
      # The snippet survives being switched off: turning it back on must not
      # cost the admin their pasted code.
      assert row.head_html == "<!-- paused -->"
    end

    test "a rejected origin explains itself and writes nothing", ctx do
      lv = mount_as_admin(ctx)

      html = save(lv, %{head_html: "<!-- x -->", script_src: "*", enabled: "true"})

      # The page surfaces the validation's own message rather than the generic
      # fallback, so the admin learns *why* a bare wildcard is refused.
      assert html =~ "is not an allowed CSP source"
      # It names the field, so an admin with three origin boxes knows which one
      # to fix...
      assert html =~ "Invalid value provided for script_src"
      # ...and the offending value is interpolated, not left as a literal
      # `%{value}`: a Splode message only substitutes its `vars` through
      # `Exception.message/1`, so reading `.message` off the struct anywhere in
      # this path would ship the placeholder to the admin.
      refute html =~ "%{value}"

      assert {:ok, []} = CMS.list_site_code_injection(tenant: ctx.org, authorize?: false)
    end

    test "the rejected input is still on the form afterwards", ctx do
      lv = mount_as_admin(ctx)

      html = save(lv, %{head_html: "<!-- mine -->", script_src: "*", enabled: "true"})

      # A form that clears itself on a validation error makes the admin retype
      # a snippet they may have pasted from elsewhere.
      assert html =~ "&lt;!-- mine --&gt;"
    end

    test "validate keeps what was typed without writing it", ctx do
      lv = mount_as_admin(ctx)

      html =
        lv
        |> form("#code-injection-form", injection: %{head_html: "<!-- draft -->"})
        |> render_change()

      assert html =~ "&lt;!-- draft --&gt;"
      assert {:ok, []} = CMS.list_site_code_injection(tenant: ctx.org, authorize?: false)
    end
  end

  describe "the derived hashes" do
    test "are listed after a save, so an admin can see the CSP will allow the script", ctx do
      lv = mount_as_admin(ctx)

      html =
        save(lv, %{head_html: "<script>console.log(\"hi\")</script>", enabled: "true"})

      [hash] = row!(ctx.org).script_hashes
      # Asserted against the row's own derived value: a hardcoded digest would
      # pass while the page rendered somebody else's hash.
      assert html =~ "sha256-#{hash}"
    end

    test "are absent before any save, and after a snippet with no inline script", ctx do
      lv = mount_as_admin(ctx)

      refute render(lv) =~ "sha256-"

      html = save(lv, %{head_html: ~s(<meta name="verify" content="abc" />), enabled: "true"})

      assert row!(ctx.org).script_hashes == []
      refute html =~ "sha256-"
    end
  end

  describe "removing" do
    test "clears the site's code and the form with it", ctx do
      lv = mount_as_admin(ctx)

      save(lv, %{
        head_html: "<!-- gone soon -->",
        script_src: "https://x.example",
        enabled: "true"
      })

      html = lv |> element(~s(button[phx-click="reset"])) |> render_click()

      assert html =~ "Code injection removed."
      assert {:ok, []} = CMS.list_site_code_injection(tenant: ctx.org, authorize?: false)
      refute html =~ "gone soon"
      # And the site falls back to serving nothing at all.
      refute KilnCMS.CodeInjection.for_org(ctx.org.id).head_html
    end

    test "offers no Remove button before anything has been saved", ctx do
      lv = mount_as_admin(ctx)

      assert lv |> element(~s(button[phx-click="reset"])) |> has_element?() == false
    end

    test "a reset raced against another admin's removal is a no-op, not a crash", ctx do
      lv = mount_as_admin(ctx)
      save(lv, %{head_html: "<!-- doomed -->", enabled: "true"})

      # Someone else removed the row between this page's last render and the
      # click — the button is still in this admin's DOM.
      CMS.reset_site_code_injection!(row!(ctx.org), authorize?: false, tenant: ctx.org)

      assert render_click(lv, "reset") =~ "Code injection"
      assert {:ok, []} = CMS.list_site_code_injection(tenant: ctx.org, authorize?: false)
    end
  end

  defp mount_as_admin(%{conn: conn, org: org}) do
    {:ok, lv, _html} =
      conn |> org_conn(org) |> log_in(authed_user(:admin)) |> live(~p"/editor/code-injection")

    lv
  end

  defp save(lv, params) do
    lv |> form("#code-injection-form", injection: params) |> render_submit()
  end

  defp row!(org) do
    {:ok, [row]} = CMS.list_site_code_injection(tenant: org, authorize?: false)
    row
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Injection Site",
      slug: "injectlive-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp grant_org_admin(user, org), do: grant_tier(user, org, :admin)

  defp grant_tier(user, org, tier) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp authed_user(role) do
    email = "injectlive-#{role}-#{System.unique_integer([:positive])}@example.com"

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
end
