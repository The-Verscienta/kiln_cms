defmodule KilnCMSWeb.InviteLiveTest do
  @moduledoc """
  The page a site invitation's link opens (`/auth/invite/:invite_token`, #2135),
  end to end: the new-account form, the one-click accept for a confirmed
  account, the take-over of an unconfirmed one, invite-only mode, an account
  that appears between opening the page and submitting it, and the invited
  site's own host.

  `async: false`: tests flip `:registration_enabled` and `:console_host`
  with `Application.put_env`, which is node-wide.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.MailAssertions
  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Accounts.User
  alias KilnCMSWeb.Tenant

  @moduletag :capture_log

  @password "invitee-password-123"
  @old_password "existing-password-456"

  defp uniq, do: System.unique_integer([:positive])
  defp address, do: "invite-live-#{uniq()}@example.com"

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: address(),
          hashed_password: Bcrypt.hash_pwd_salt(@old_password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp invite!(attrs \\ %{}) do
    invitation =
      Accounts.invite_to_org!(
        Map.merge(
          %{organization_id: Accounts.default_org_id(), email: address(), role: :editor},
          attrs
        ),
        actor: user(:admin)
      )

    {invitation, invitation.__metadata__.token}
  end

  defp signs_in?(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    match?(
      {:ok, _},
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => to_string(email), "password" => password},
        []
      )
    )
  end

  defp membership(user_id, org_id) do
    Accounts.list_memberships_for_user!(user_id, authorize?: false)
    |> Enum.find(&(&1.organization_id == org_id))
  end

  defp submit_password(view, password \\ @password) do
    view
    |> form("#invite-form", %{
      "invite" => %{
        "name" => "Ada",
        "password" => password,
        "password_confirmation" => password
      }
    })
    |> render_submit()
  end

  test "no account: the invitee sets a password, lands on sign-in and can sign in", %{conn: conn} do
    {invitation, token} = invite!()
    {:ok, view, html} = live(conn, ~p"/auth/invite/#{token}")

    assert html =~ to_string(invitation.email)
    assert html =~ "an editor"
    assert has_element?(view, "#invite-form")

    assert {:error, {:redirect, %{to: "/sign-in"}}} = submit_password(view)

    {:ok, user} = Accounts.get_user_by_email(to_string(invitation.email), authorize?: false)
    assert user.name == "Ada"
    assert membership(user.id, Accounts.default_org_id()).role == :editor
    assert signs_in?(user.email, @password)
    assert Invitations.peek(token) == nil
  end

  test "opening the page consumes nothing", %{conn: conn} do
    {_invitation, token} = invite!()
    {:ok, _view, _html} = live(conn, ~p"/auth/invite/#{token}")
    {:ok, _view, _html} = live(conn, ~p"/auth/invite/#{token}")
    assert Invitations.peek(token)
  end

  test "a confirmed account accepts with one click and keeps its password", %{conn: conn} do
    site = org("existing")
    {invitation, token} = invite!(%{organization_id: site.id})
    owner = user(:viewer, %{email: to_string(invitation.email)})

    {:ok, view, _html} =
      live(%{conn | host: "#{site.slug}.#{Tenant.base_host()}"}, ~p"/auth/invite/#{token}")

    refute has_element?(view, "#invite-form")

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             view |> element("#invite-accept") |> render_click()

    assert %{"info" => "You've joined" <> _} = assert_redirect(view, "/sign-in")
    assert membership(owner.id, site.id).role == :editor
    assert signs_in?(owner.email, @old_password)
    assert Invitations.peek(token) == nil
  end

  describe "an account already on the invited site (#2452)" do
    setup do
      site = org("invite-member")
      %{site: site, conn: %{build_conn() | host: "#{site.slug}.#{Tenant.base_host()}"}}
    end

    defp member!(user, org_id, role),
      do:
        Ash.Seed.seed!(Accounts.OrgMembership, %{
          organization_id: org_id,
          user_id: user.id,
          role: role
        })

    defp accept_click(conn, token) do
      {:ok, view, _html} = live(conn, ~p"/auth/invite/#{token}")
      assert {:error, {:redirect, _}} = view |> element("#invite-accept") |> render_click()
      assert_redirect(view, "/sign-in")
    end

    test "a lower membership is raised, and the page says so", %{conn: conn, site: site} do
      {invitation, token} = invite!(%{organization_id: site.id, role: :editor})
      owner = user(:viewer, %{email: to_string(invitation.email)})
      member!(owner, site.id, :viewer)

      assert %{"info" => info} = accept_click(conn, token)

      assert info =~ "now an editor on"
      assert membership(owner.id, site.id).role == :editor
    end

    test "a higher membership is left alone, and the page does not claim a join",
         %{conn: conn, site: site} do
      {invitation, token} = invite!(%{organization_id: site.id, role: :viewer})
      owner = user(:viewer, %{email: to_string(invitation.email)})
      member!(owner, site.id, :editor)

      assert %{"info" => info} = accept_click(conn, token)

      assert info =~ "already a member of"
      assert info =~ "as an editor; nothing changed"
      refute info =~ "joined"
      assert membership(owner.id, site.id).role == :editor
      assert Invitations.peek(token) == nil
    end

    test "the password path says the same about a raise", %{conn: conn, site: site} do
      {invitation, token} = invite!(%{organization_id: site.id, role: :admin})
      squatter = user(:viewer, %{email: to_string(invitation.email), confirmed_at: nil})
      member!(squatter, site.id, :editor)

      {:ok, view, _html} = live(conn, ~p"/auth/invite/#{token}")

      assert {:error, {:redirect, %{to: "/sign-in"}}} = submit_password(view)
      assert %{"info" => info} = assert_redirect(view, "/sign-in")

      assert info =~ "now an admin on"
      assert membership(squatter.id, site.id).role == :admin
    end

    test "the password path over a higher membership says it is unchanged",
         %{conn: conn, site: site} do
      {invitation, token} = invite!(%{organization_id: site.id, role: :viewer})
      squatter = user(:viewer, %{email: to_string(invitation.email), confirmed_at: nil})
      member!(squatter, site.id, :editor)

      {:ok, view, _html} = live(conn, ~p"/auth/invite/#{token}")

      assert {:error, {:redirect, %{to: "/sign-in"}}} = submit_password(view)
      assert %{"info" => info} = assert_redirect(view, "/sign-in")

      assert info =~ "already a member of"
      assert info =~ "as an editor, and that is unchanged"
      assert membership(squatter.id, site.id).role == :editor
    end
  end

  test "an unconfirmed account is taken over: the stranger's password stops working", %{
    conn: conn
  } do
    {invitation, token} = invite!()
    squatter = user(:viewer, %{email: to_string(invitation.email), confirmed_at: nil})
    assert signs_in?(squatter.email, @old_password)

    {:ok, view, html} = live(conn, ~p"/auth/invite/#{token}")
    assert html =~ "unconfirmed account"

    assert {:error, {:redirect, %{to: "/sign-in"}}} = submit_password(view)

    refute signs_in?(squatter.email, @old_password)
    assert signs_in?(squatter.email, @password)
    assert membership(squatter.id, Accounts.default_org_id()).role == :editor
  end

  test "a takeover forgets the stranger's second factor and passkeys, says so, and logs it",
       %{conn: conn} do
    {invitation, token} = invite!()

    squatter =
      user(:viewer, %{email: to_string(invitation.email), confirmed_at: nil})
      |> Ash.Seed.update!(%{
        totp_secret: KilnCMS.Accounts.Totp.generate_secret(),
        totp_confirmed_at: DateTime.utc_now()
      })

    {:ok, _passkey} = KilnCMS.PasskeyFixtures.enroll(squatter, "invite-live-cred-#{uniq()}")

    {:ok, view, _html} = live(conn, ~p"/auth/invite/#{token}")

    assert {:error, {:redirect, %{to: "/sign-in"}}} = submit_password(view)
    assert %{"info" => info} = assert_redirect(view, "/sign-in")
    assert info =~ "passkeys or API keys set up on this address before were removed"

    {:ok, user} = Accounts.get_user_by_email(to_string(invitation.email), authorize?: false)
    refute Accounts.totp_enabled?(user)

    # Recorded in the log of the site the page was opened on, with no actor.
    types =
      KilnCMS.Security.list_events!(actor: user(:admin), tenant: Accounts.default_org_id())
      |> then(fn
        %{results: results} -> results
        list -> list
      end)
      |> Enum.filter(&(&1.target_id == squatter.id and is_nil(&1.actor_id)))
      |> Enum.map(& &1.type)

    assert :second_factor_removed in types
    assert :passkey_removed in types
  end

  test "a takeover with nothing to forget says nothing about it", %{conn: conn} do
    {invitation, token} = invite!()
    user(:viewer, %{email: to_string(invitation.email), confirmed_at: nil})

    {:ok, view, _html} = live(conn, ~p"/auth/invite/#{token}")

    assert {:error, {:redirect, %{to: "/sign-in"}}} = submit_password(view)
    assert %{"info" => info} = assert_redirect(view, "/sign-in")
    refute info =~ "were removed"
  end

  test "invite-only mode does not stop an invitee", %{conn: conn} do
    previous = Application.get_env(:kiln_cms, :registration_enabled)
    Application.put_env(:kiln_cms, :registration_enabled, false)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:kiln_cms, :registration_enabled),
        else: Application.put_env(:kiln_cms, :registration_enabled, previous)
    end)

    {_invitation, token} = invite!()
    {:ok, view, _html} = live(conn, ~p"/auth/invite/#{token}")
    assert {:error, {:redirect, %{to: "/sign-in"}}} = submit_password(view)
  end

  test "an account made after the invitation (single sign-on, say) gets the accept button",
       %{conn: conn} do
    {invitation, token} = invite!()
    # What an identity provider's first sign-in leaves: a confirmed account.
    user(:viewer, %{email: to_string(invitation.email)})

    {:ok, view, _html} = live(conn, ~p"/auth/invite/#{token}")
    assert has_element?(view, "#invite-accept")
    refute has_element?(view, "#invite-form")
  end

  test "an account that appears while the form is open: told so, nothing set", %{conn: conn} do
    {invitation, token} = invite!()
    {:ok, view, _html} = live(conn, ~p"/auth/invite/#{token}")
    assert has_element?(view, "#invite-form")

    owner = user(:viewer, %{email: to_string(invitation.email)})

    html = submit_password(view)
    assert html =~ "already exists"
    assert has_element?(view, "#invite-accept")
    assert signs_in?(owner.email, @old_password)
    assert Invitations.peek(token)
  end

  test "a mismatched confirmation is shown and the link still works", %{conn: conn} do
    {_invitation, token} = invite!()
    {:ok, view, _html} = live(conn, ~p"/auth/invite/#{token}")

    html =
      view
      |> form("#invite-form", %{
        "invite" => %{"password" => @password, "password_confirmation" => "different-999"}
      })
      |> render_submit()

    assert html =~ "invite-error"
    assert Invitations.peek(token)
  end

  test "pushed payloads of the wrong shape change nothing", %{conn: conn} do
    {_invitation, token} = invite!()
    {:ok, view, _html} = live(conn, ~p"/auth/invite/#{token}")

    render_hook(view, "accept_new", %{"invite" => "not-a-map"})
    render_hook(view, "accept_new", %{"invite" => %{"password" => ["x"]}})
    render_hook(view, "accept_new", %{})
    # The confirmed-account button on a page that is showing the form.
    render_hook(view, "accept_existing", %{})

    assert Invitations.peek(token)
    assert has_element?(view, "#invite-form")
  end

  test "an unknown token gets the fixed invalid page", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/auth/invite/#{Invitations.generate_token()}")
    assert has_element?(view, "#invite-invalid")
    assert html =~ "no longer valid"
    refute has_element?(view, "#invite-form")
  end

  describe "the invited site's own host" do
    setup do
      previous = Application.get_env(:kiln_cms, :console_host)
      console = "console#{uniq()}.#{Tenant.base_host()}"
      Application.put_env(:kiln_cms, :console_host, console)
      KilnCMS.Cache.Hosts.clear()

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:kiln_cms, :console_host),
          else: Application.put_env(:kiln_cms, :console_host, previous)

        KilnCMS.Cache.Hosts.clear()
      end)

      %{console: console}
    end

    test "a viewer's link opens on the site host, an editor's on the console host",
         %{conn: conn, console: console} do
      site = org("tiered")
      {viewer_invitation, viewer_token} = invite!(%{organization_id: site.id, role: :viewer})
      {editor_invitation, editor_token} = invite!(%{organization_id: site.id, role: :editor})
      site_host = "#{site.slug}.#{Tenant.base_host()}"
      console_host = "#{site.slug}.#{console}"

      KilnCMS.DataCase.drain_oban()

      # Drained together, the mails arrive in no fixed order: Oban fetches the
      # :mail queue through UPDATE ... RETURNING, whose row order Postgres does
      # not guarantee. So assert the set (#2602).
      expected = [
        {viewer_invitation, viewer_token, site_host},
        {editor_invitation, editor_token, console_host}
      ]

      # Pick each mail out by recipient first, then assert on it, so a wrong
      # host or path fails with its values rather than as "unmatched".
      mails =
        assert_delivered(
          for {invitation, _token, _host} <- expected do
            &(&1.to == [{"", to_string(invitation.email)}])
          end
        )

      for {mail, {_invitation, token, host}} <- Enum.zip(mails, expected) do
        [link] = Regex.run(~r{href="([^"]+)"}, mail.html_body, capture: :all_but_first)
        assert URI.parse(link).host == host
        assert URI.parse(link).path == "/auth/invite/#{token}"
      end

      # The viewer's link opened on the site's console host goes to the site host.
      assert {:error, {:redirect, %{to: to}}} =
               live(%{conn | host: console_host}, ~p"/auth/invite/#{viewer_token}")

      assert URI.parse(to).host == site_host

      # And where it points, it is served.
      {:ok, view, _html} = live(%{conn | host: site_host}, ~p"/auth/invite/#{viewer_token}")
      assert has_element?(view, "#invite-form")
    end

    test "the mailed link names the site's console host, and another host redirects there",
         %{conn: conn, console: console} do
      site = org("hosted")
      {invitation, token} = invite!(%{organization_id: site.id})
      host = "#{site.slug}.#{console}"

      KilnCMS.DataCase.drain_oban()

      assert_email_sent(fn mail ->
        [link] = Regex.run(~r{href="([^"]+)"}, mail.html_body, capture: :all_but_first)
        assert URI.parse(link).host == host
        assert URI.parse(link).path == "/auth/invite/#{token}"
        mail.to == [{"", to_string(invitation.email)}]
      end)

      # Opened on the default site's host: sent to the invited site's.
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/auth/invite/#{token}")
      assert URI.parse(to).host == host
      assert URI.parse(to).path == "/auth/invite/#{token}"

      # Opened where the link points: served, and the invitee is set up there.
      {:ok, view, _html} = live(%{conn | host: host}, ~p"/auth/invite/#{token}")
      assert {:error, {:redirect, %{to: "/sign-in"}}} = submit_password(view)
      {:ok, user} = Accounts.get_user_by_email(to_string(invitation.email), authorize?: false)
      assert membership(user.id, site.id).role == :editor
    end
  end
end
