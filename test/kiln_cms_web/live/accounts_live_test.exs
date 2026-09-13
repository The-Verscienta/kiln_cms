defmodule KilnCMSWeb.AccountsLiveTest do
  @moduledoc "The instance-wide account register (`/editor/accounts`)."
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{RoleGrant, User}

  @password "password123456"

  defp seeded(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "accounts-live-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp authed_user(role) do
    user = seeded(role)
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => to_string(user.email),
        "password" => @password
      })

    signed_in
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp in_hours(hours), do: DateTime.add(DateTime.utc_now(), hours, :hour)

  defp reread(user), do: Accounts.get_user!(user.id, RoleGrant.unfolded() ++ [authorize?: false])

  describe "authorization" do
    test "anonymous users are redirected to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/editor/accounts")
    end

    test "editors are turned away", %{conn: conn} do
      conn = log_in(conn, authed_user(:editor))
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/editor/accounts")
    end
  end

  describe "the register" do
    setup %{conn: conn} do
      %{conn: log_in(conn, authed_user(:admin)), other: seeded(:editor, %{name: "Dana Reed"})}
    end

    test "lists registered accounts with their role", %{conn: conn, other: other} do
      {:ok, _view, html} = live(conn, ~p"/editor/accounts")

      assert html =~ to_string(other.email)
      assert html =~ "Dana Reed"
      assert html =~ "editor"
    end

    test "searches by email", %{conn: conn, other: other} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts")

      html =
        view
        |> form("#account-filters", %{"q" => to_string(other.email)})
        |> render_change()

      assert html =~ to_string(other.email)
    end

    test "search excludes non-matching accounts", %{conn: conn, other: other} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts")

      html =
        view
        |> form("#account-filters", %{"q" => "definitely-not-a-registered-address"})
        |> render_change()

      refute html =~ to_string(other.email)
      assert html =~ "No accounts match"
    end

    test "filters by role", %{conn: conn, other: other} do
      viewer = seeded(:viewer)
      {:ok, view, _html} = live(conn, ~p"/editor/accounts")

      html = view |> form("#account-filters", %{"role" => "viewer"}) |> render_change()

      assert html =~ to_string(viewer.email)
      refute html =~ to_string(other.email)
    end

    test "filters to accounts holding a temporary role", %{conn: conn, other: other} do
      admin = seeded(:admin)
      plain = seeded(:viewer)

      {:ok, _} =
        Accounts.grant_user_temporary_role(
          other,
          %{granted_role: :admin, granted_role_expires_at: in_hours(5)},
          actor: admin
        )

      {:ok, view, _html} = live(conn, ~p"/editor/accounts")
      html = view |> form("#account-filters", %{"status" => "temporary"}) |> render_change()

      assert html =~ to_string(other.email)
      refute html =~ to_string(plain.email)
    end
  end

  describe "client-shaped input" do
    setup %{conn: conn} do
      %{conn: log_in(conn, authed_user(:admin))}
    end

    # `?page[]=1` decodes to a list; it used to reach `Integer.parse/1` and crash.
    test "bracketed query parameters read as absent", %{conn: conn} do
      assert {:ok, _view, html} =
               live(conn, "/editor/accounts?page[]=2&q[]=x&role[a]=admin&status[]=erased")

      assert html =~ "Accounts"
    end

    # On the register there is no account; a pushed account event must not
    # dereference nil.
    test "account events pushed on the register are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts")

      for event <- ~w(send_password_reset sign_out_everywhere confirm_removal revoke_grant) do
        assert render_hook(view, event, %{}) =~ "Accounts"
      end

      assert render_hook(view, "page", %{"to" => ["2"]}) =~ "Accounts"
      assert render_hook(view, "save_access", %{}) =~ "Accounts"
    end
  end

  describe "one account" do
    setup %{conn: conn} do
      admin = authed_user(:admin)
      %{conn: log_in(conn, admin), admin: admin, subject: seeded(:viewer)}
    end

    test "shows the account's facts", %{conn: conn, subject: subject} do
      {:ok, _view, html} = live(conn, ~p"/editor/accounts/#{subject.id}")

      assert html =~ to_string(subject.email)
      assert html =~ "Platform access"
      assert html =~ "Temporary role"
    end

    test "an unknown id redirects to the register", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/editor/accounts"}}} =
               live(conn, ~p"/editor/accounts/#{Ash.UUID.generate()}")
    end

    test "changes the standing role", %{conn: conn, subject: subject} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")

      html = view |> form("#access-form", %{"access" => %{"role" => "editor"}}) |> render_submit()

      assert html =~ "Access updated"
      assert reread(subject).role == :editor
    end

    test "grants and then ends a temporary role", %{conn: conn, subject: subject} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")

      html =
        view
        |> form("#grant-form", %{"grant" => %{"role" => "editor", "hours" => "24"}})
        |> render_submit()

      assert html =~ "Editor until"
      granted = reread(subject)
      assert granted.granted_role == :editor
      # The standing role is untouched — that is what makes expiry a comparison.
      assert granted.role == :viewer

      html = view |> element("button", "End it now") |> render_click()
      assert html =~ "Temporary role ended"
      assert is_nil(reread(subject).granted_role)
    end

    # "Expires after a customized period" means an arbitrary moment too, not only
    # one of the offered durations.
    test "an explicit expiry wins over the preset duration", %{conn: conn, subject: subject} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")
      until = DateTime.utc_now() |> DateTime.add(11, :day) |> Calendar.strftime("%Y-%m-%dT%H:%M")

      view
      |> form("#grant-form", %{
        "grant" => %{"role" => "editor", "hours" => "24", "until" => until}
      })
      |> render_submit()

      granted = reread(subject)
      assert granted.granted_role == :editor
      # 11 days, not the 24 hours the select still carried.
      assert DateTime.diff(granted.granted_role_expires_at, DateTime.utc_now(), :day) >= 10
    end

    # Some browsers send `datetime-local` with seconds, some without; both must be
    # honoured rather than quietly falling back to the preset. A fresh account per
    # shape, so neither run has to revoke the other's grant first.
    for {label, suffix} <- [{"without seconds", ""}, {"with seconds", ":30"}] do
      test "an explicit expiry is read #{label}", %{conn: conn} do
        subject = seeded(:viewer)
        {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")

        until =
          DateTime.utc_now()
          |> DateTime.add(13, :day)
          |> Calendar.strftime("%Y-%m-%dT%H:%M")
          |> Kernel.<>(unquote(suffix))

        view
        |> form("#grant-form", %{
          "grant" => %{"role" => "editor", "hours" => "24", "until" => until}
        })
        |> render_submit()

        granted = reread(subject)
        assert granted.granted_role == :editor
        assert DateTime.diff(granted.granted_role_expires_at, DateTime.utc_now(), :day) >= 12
      end
    end

    # A browser that renders `datetime-local` as a text box accepts anything. An
    # unparseable value falls back to the preset instead of becoming a nil expiry.
    test "an unparseable explicit expiry falls back to the preset", %{
      conn: conn,
      subject: subject
    } do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")

      view
      |> form("#grant-form", %{
        "grant" => %{"role" => "editor", "hours" => "72", "until" => "23/09/2026 14:30"}
      })
      |> render_submit()

      granted = reread(subject)
      assert granted.granted_role == :editor
      assert DateTime.diff(granted.granted_role_expires_at, DateTime.utc_now(), :hour) >= 71
    end

    test "a blank explicit expiry falls back to the preset", %{conn: conn, subject: subject} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")

      view
      |> form("#grant-form", %{
        "grant" => %{"role" => "editor", "hours" => "168", "until" => ""}
      })
      |> render_submit()

      granted = reread(subject)
      assert DateTime.diff(granted.granted_role_expires_at, DateTime.utc_now(), :day) >= 6
    end

    # A stale or fat-fingered datetime is refused with a message rather than
    # silently becoming "no expiry", which `RoleGrant` would read as no grant.
    test "an expiry in the past is refused", %{conn: conn, subject: subject} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")
      past = DateTime.utc_now() |> DateTime.add(-2, :day) |> Calendar.strftime("%Y-%m-%dT%H:%M")

      html =
        view
        |> form("#grant-form", %{
          "grant" => %{"role" => "editor", "hours" => "24", "until" => past}
        })
        |> render_submit()

      assert html =~ "must be in the future"
      assert is_nil(reread(subject).granted_role)
    end

    test "offers only tiers above the standing one", %{conn: conn} do
      admin = seeded(:admin)
      {:ok, _view, html} = live(conn, ~p"/editor/accounts/#{admin.id}")

      assert html =~ "already holds the highest role"
      refute html =~ "grant-form"
    end

    test "sends a password reset", %{conn: conn, subject: subject} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")

      html = view |> element("button", "Send password reset") |> render_click()

      assert html =~ "Sent a reset link to"
    end

    test "signs the account out everywhere", %{conn: conn, subject: subject} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")

      html = view |> element("button", "Sign out everywhere") |> render_click()

      assert html =~ "Signed out of every session"
    end
  end

  describe "removal" do
    setup %{conn: conn} do
      admin = authed_user(:admin)
      # A spare admin so the last-admin guard isn't what refuses the erasure.
      _spare = seeded(:admin)
      %{conn: log_in(conn, admin), subject: seeded(:editor)}
    end

    test "asks before erasing, then erases", %{conn: conn, subject: subject} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")

      html = view |> element("button", "Delete account…") |> render_click()
      assert html =~ "Delete #{subject.email}?"
      assert html =~ "authored nothing"

      view |> element("#removal-confirm button", "Delete, keep content") |> render_click()

      erased = Accounts.get_user!(subject.id, authorize?: false)
      assert erased.anonymized_at
      assert to_string(erased.email) == "anonymized-#{subject.id}@deleted.invalid"
    end

    test "the confirmation can be dismissed", %{conn: conn, subject: subject} do
      {:ok, view, _html} = live(conn, ~p"/editor/accounts/#{subject.id}")

      view |> element("button", "Delete account…") |> render_click()
      html = view |> element("button", "Cancel") |> render_click()

      refute html =~ "removal-confirm"
      assert is_nil(Accounts.get_user!(subject.id, authorize?: false).anonymized_at)
    end

    test "an already-erased account offers no delete", %{conn: conn, subject: subject} do
      admin = seeded(:admin)
      {:ok, _} = Accounts.anonymize_user(subject, actor: admin)

      {:ok, _view, html} = live(conn, ~p"/editor/accounts/#{subject.id}")

      assert html =~ "was erased on"
      refute html =~ "Delete account…"
    end
  end
end
