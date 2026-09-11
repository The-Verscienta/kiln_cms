defmodule KilnCMSWeb.SetupLiveTest do
  @moduledoc """
  The first-run setup wizard (#1317): renders only while no admin exists,
  creates exactly one confirmed admin through the policy-gated
  `:bootstrap_admin` action, and applies the optional branding as that admin.

  `async: false` — the happy path writes branding, which busts the shared
  Cachex.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Bootstrap
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  describe "the gate" do
    test "renders while no admin exists", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/setup")

      assert html =~ "Set up your site"
      assert html =~ "Create your admin account"
    end

    test "redirects home once an admin exists", %{conn: conn} do
      seed_user(:admin)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/setup")
    end

    test "a non-admin account does not close the gate", %{conn: conn} do
      # The condition is "no ADMIN", not "no users": an instance with stray
      # viewer accounts (an aborted earlier life) still has nobody who could
      # promote one.
      seed_user(:viewer)

      {:ok, _lv, html} = live(conn, ~p"/setup")

      assert html =~ "Set up your site"
    end

    test "the action itself is forbidden once an admin exists — not just the page" do
      seed_user(:admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.Changeset.for_create(:bootstrap_admin, %{
                 email: "second@example.com",
                 password: "password1234!",
                 password_confirmation: "password1234!"
               })
               |> Ash.create()
    end

    test "the locked re-check refuses a caller that raced past the policy" do
      # `Bootstrap.create_first_admin/1` re-reads under the advisory lock, so
      # even a caller who authorized before the winner committed gets refused.
      seed_user(:admin)

      assert {:error, :already_bootstrapped} =
               Bootstrap.create_first_admin(%{
                 email: "second@example.com",
                 password: "password1234!",
                 password_confirmation: "password1234!"
               })
    end
  end

  describe "the walk" do
    test "creates a confirmed admin and the branding, then sends them to sign-in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/setup")

      lv
      |> form("#setup-admin-form",
        admin: %{
          email: "owner@example.com",
          name: "Site Owner",
          password: "a-strong-password",
          password_confirmation: "a-strong-password"
        }
      )
      |> render_submit()

      lv
      |> form("#setup-site-form",
        site: %{site_name: "Owner's Site", brand_color: "#1d4ed8", theme: "editorial"}
      )
      |> render_submit()

      assert lv |> element("button[phx-click=finish]") |> render_click()
      assert_redirect(lv, ~p"/sign-in")

      {:ok, user} = Accounts.get_user_by_email("owner@example.com", authorize?: false)
      assert user.role == :admin
      assert user.name == "Site Owner"

      # Confirmed at create (auto_confirm_actions): sign-in must not wait on a
      # confirmation mail the instance cannot send yet.
      confirmed = Ash.load!(user, [:confirmed_at], authorize?: false)
      assert confirmed.confirmed_at

      assert {:ok, [row]} = CMS.list_site_branding(tenant: nil, authorize?: false)
      assert row.site_name == "Owner's Site"
      assert row.brand_color == "#1d4ed8"
      assert row.theme == :editorial

      # Something to write on first sign-in: a DRAFT Home page — never
      # published on the operator's behalf — headed with the new site's name.
      assert [home] =
               CMS.list_pages!(
                 query: [filter: [slug: "home"]],
                 authorize?: false,
                 tenant: Accounts.default_org_id()
               )

      assert home.state == :draft
      assert home.title == "Home"
      assert [heading, rich_text] = home.blocks
      assert heading.type == :heading
      assert heading.value.text == "Owner's Site"
      assert rich_text.type == :rich_text

      # "Who can publish?" was left on its default: editors publish.
      assert KilnCMS.CMS.EditorialSettings.editors_can_publish?(Accounts.default_org_id())

      on_exit(fn -> KilnCMS.Cache.bust_branding(Accounts.default_org_id()) end)
    end

    test "a finished instance refuses a second finish from a stale tab", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/setup")

      lv
      |> form("#setup-admin-form",
        admin: %{
          email: "late@example.com",
          password: "a-strong-password",
          password_confirmation: "a-strong-password"
        }
      )
      |> render_submit()

      lv |> form("#setup-site-form", site: %{}) |> render_submit()

      # Someone else finished first while this tab sat on the review step.
      seed_user(:admin)

      lv |> element("button[phx-click=finish]") |> render_click()
      assert_redirect(lv, ~p"/")

      refute Accounts.get_user_by_email!("late@example.com",
               authorize?: false,
               not_found_error?: false
             )
    end

    test "choosing admin approval keeps publishing an admin step", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/setup")

      lv
      |> form("#setup-admin-form",
        admin: %{
          email: "reviewed@example.com",
          password: "a-strong-password",
          password_confirmation: "a-strong-password"
        }
      )
      |> render_submit()

      html = lv |> form("#setup-site-form", site: %{editors_publish: "false"}) |> render_submit()
      assert html =~ "An admin approves everything"

      lv |> element("button[phx-click=finish]") |> render_click()
      assert_redirect(lv, ~p"/sign-in")

      refute KilnCMS.CMS.EditorialSettings.editors_can_publish?(Accounts.default_org_id())
    end

    test "a password mismatch stays on step 1 with the problem named", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/setup")

      html =
        lv
        |> form("#setup-admin-form",
          admin: %{
            email: "owner@example.com",
            password: "a-strong-password",
            password_confirmation: "a-different-password"
          }
        )
        |> render_submit()

      assert html =~ "The passwords don&#39;t match."
      assert has_element?(lv, "#setup-admin-form")
    end

    test "branding is optional — an all-default site step writes no row", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/setup")

      lv
      |> form("#setup-admin-form",
        admin: %{
          email: "plain@example.com",
          password: "a-strong-password",
          password_confirmation: "a-strong-password"
        }
      )
      |> render_submit()

      lv |> form("#setup-site-form", site: %{}) |> render_submit()
      lv |> element("button[phx-click=finish]") |> render_click()
      assert_redirect(lv, ~p"/sign-in")

      assert {:ok, []} = CMS.list_site_branding(tenant: nil, authorize?: false)
    end
  end

  defp seed_user(role) do
    Ash.Seed.seed!(User, %{
      email: "setup-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end
end
