defmodule KilnCMSWeb.SettingsPushAndPasskeysTest do
  @moduledoc """
  The two halves of `/editor/settings` nothing drove: the push-device list
  (#628) and the passkey list (#331), plus the profile form beside them.

  `settings_live_test.exs` covers the sidebar preset, notification checkboxes,
  password and TOTP. What was left is where the page manages a *credential or a
  device*: both lists are keyed by an id the browser sends back, so the handler
  has to answer the question "is this row yours?" rather than trusting the id —
  and removing the wrong row costs somebody a second factor, or leaves a device
  receiving notifications after they turned it off.

  `async: false` — the push tests configure VAPID keys, which is app env.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.Push
  alias KilnCMS.Push.Vapid

  @password "password123456"

  setup %{conn: conn} do
    original = Application.get_env(:kiln_cms, KilnCMS.Push, [])
    {public, private} = Vapid.generate()

    Application.put_env(
      :kiln_cms,
      KilnCMS.Push,
      Keyword.merge(original,
        vapid_public_key: public,
        vapid_private_key: private,
        vapid_subject: "mailto:ops@example.com"
      )
    )

    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Push, original) end)

    user = authed_user(:editor)
    %{conn: log_in(conn, user), user: user}
  end

  defp authed_user(role) do
    email = "settings-devices-#{System.unique_integer([:positive])}@example.com"

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

  # What the PushToggle hook sends back after the browser subscribes.
  defp subscription_params(label \\ "iOS · Safari") do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "endpoint" => "https://push.example.com/x/#{System.unique_integer([:positive])}",
      "p256dh" => Base.url_encode64(public, padding: false),
      "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "label" => label
    }
  end

  defp devices(user), do: Push.list(user)

  describe "push devices" do
    test "a subscribed device is stored and listed", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/editor/settings")
      assert html =~ "Turn on for this device"

      html = render_hook(view, "push_subscribed", subscription_params("Pixel · Chrome"))

      assert html =~ "Notifications are on for this device."
      assert html =~ "Pixel · Chrome"
      assert html =~ "Turn off on this device"
      assert [%{label: "Pixel · Chrome"}] = devices(user)
    end

    test "unsubscribing this device turns it off and drops it from the list", %{
      conn: conn,
      user: user
    } do
      params = subscription_params("Old tablet")
      {:ok, view, _html} = live(conn, ~p"/editor/settings")
      assert render_hook(view, "push_subscribed", params) =~ "Old tablet"

      html = render_hook(view, "push_unsubscribed", %{"endpoint" => params["endpoint"]})

      assert html =~ "Notifications are off for this device."
      assert html =~ "Turn on for this device"
      assert devices(user) == []
      # Gone from the page too, not just from the table: a device still listed
      # reads as one still receiving.
      refute html =~ "Old tablet"
    end

    test "remove takes the named device, leaving the others", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")
      render_hook(view, "push_subscribed", subscription_params("Phone"))
      render_hook(view, "push_subscribed", subscription_params("Laptop"))
      [phone] = Enum.filter(devices(user), &(&1.label == "Phone"))

      html = render_click(view, "remove_push_device", %{"id" => phone.id})

      assert html =~ "Device removed."
      assert [%{label: "Laptop"}] = devices(user)
    end

    test "another account's device id is ignored, not removed", %{conn: conn, user: user} do
      other = authed_user(:editor)

      {:ok, other_device} =
        Push.subscribe(subscription_params("Someone else's phone"), other, nil)

      {:ok, view, _html} = live(conn, ~p"/editor/settings")
      render_hook(view, "push_subscribed", subscription_params("Mine"))

      html = render_click(view, "remove_push_device", %{"id" => other_device.id})

      # Silent, but above all harmless: the other account keeps its device, and
      # this page keeps its own.
      refute html =~ "Device removed."
      assert [%{label: "Someone else's phone"}] = devices(other)
      assert [%{label: "Mine"}] = devices(user)
    end

    test "a browser that cannot do push hides the toggle's promise", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      html = render_hook(view, "push_unsupported", %{})

      assert html =~ "This browser can&#39;t receive push notifications."
      assert html =~ "disabled"
    end

    test "a blocked permission says how to undo it, and claims nothing is on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      html = render_hook(view, "push_denied", %{})

      assert html =~ "Your browser is blocking notifications for this site."
      assert html =~ "Turn on for this device"
    end

    test "a failed registration says so rather than looking successful", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      html = render_hook(view, "push_failed", %{})

      assert html =~ "Couldn&#39;t register this device for notifications."
      assert html =~ "Turn on for this device"
    end

    test "the hook's state report decides which way the toggle reads", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      assert render_hook(view, "push_state", %{"subscribed" => true}) =~
               "Turn off on this device"

      assert render_hook(view, "push_state", %{"subscribed" => false}) =~
               "Turn on for this device"
    end

    test "with no VAPID keys the section is not offered at all", %{conn: conn} do
      original = Application.get_env(:kiln_cms, KilnCMS.Push, [])
      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Push, original) end)

      Application.put_env(
        :kiln_cms,
        KilnCMS.Push,
        Keyword.drop(original, [:vapid_public_key, :vapid_private_key])
      )

      {:ok, _view, html} = live(conn, ~p"/editor/settings")

      # Offering a switch the server cannot honour is worse than not offering
      # one: the browser would prompt for permission and nothing would arrive.
      refute html =~ "push-settings"
      refute html =~ "Turn on for this device"
    end
  end

  describe "passkeys" do
    test "removing an id that is not this user's passkey is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      html = render_click(view, "remove_passkey", %{"id" => Ecto.UUID.generate()})

      assert html =~ "Couldn&#39;t remove that passkey."
    end

    test "a browser that refuses the prompt leaves a message, not a half-made passkey",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      html = render_hook(view, "passkey_error", %{"message" => "user cancelled"})

      assert html =~ "Add a passkey"
      refute html =~ "Passkey added"
    end

    test "beginning enrolment hands the browser a challenge", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      view |> form("#add-passkey-form", %{"name" => "MacBook Touch ID"}) |> render_submit()

      # The challenge goes to the PasskeyEnroll hook as a pushed event; the
      # server half is what this asserts, since the browser half cannot run here.
      assert_push_event(view, "passkey-register", %{
        publicKey: %{challenge: challenge, user: %{name: name}},
        name: "MacBook Touch ID"
      })

      # The challenge is per-attempt, and the account it enrols for is this one.
      assert is_binary(challenge)
      assert name == to_string(ctx.user.email)
    end
  end

  describe "profile" do
    test "the display name is saved, and it is the byline it claims to be", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      html =
        view |> form("#profile-form", user: %{name: "Ada Lovelace"}) |> render_submit()

      assert html =~ "Ada Lovelace"
      assert Ash.get!(User, user.id, authorize?: false).name == "Ada Lovelace"
    end
  end
end
