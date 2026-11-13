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

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.Passkey
  alias KilnCMS.Accounts.User
  alias KilnCMS.Accounts.WebAuthn
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
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # What the PushToggle hook sends back after the browser subscribes.
  defp subscription_params(label) do
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

    # #1829: whether one is set up was left to be read off an empty space,
    # and the name field's placeholder said "Passkey" as if one existed.
    test "says plainly when there are none, and how many when there are", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      assert has_element?(view, "#passkeys-none", "No passkeys yet")
      refute has_element?(view, "#passkeys-count")
      refute has_element?(view, ~s(#add-passkey-form input[placeholder="Passkey"]))

      Ash.Seed.seed!(KilnCMS.Accounts.Passkey, %{
        user_id: user.id,
        name: "Work laptop",
        credential_id: "settings-#{System.unique_integer([:positive])}",
        public_key: :erlang.term_to_binary(%{stub: :cose_key}),
        sign_count: 0
      })

      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      assert has_element?(view, "#passkeys-count", "You have 1 passkey set up.")
      assert has_element?(view, "#passkeys li", "Work laptop")
      refute has_element?(view, "#passkeys-none")
    end

    test "waits visibly while the browser prompt is open, and can be cancelled", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      view |> form("#add-passkey-form", %{"name" => ""}) |> render_submit()

      assert has_element?(view, "#passkey-waiting", "Waiting for your device")
      refute has_element?(view, "#add-passkey-form")

      view |> element("#passkey-waiting button", "Cancel") |> render_click()

      refute has_element?(view, "#passkey-waiting")
      assert has_element?(view, "#add-passkey-form")
    end

    test "a refused prompt ends the wait and says why, in the section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      view |> form("#add-passkey-form", %{"name" => ""}) |> render_submit()
      render_hook(view, "passkey_error", %{})

      refute has_element?(view, "#passkey-waiting")
      assert has_element?(view, "#passkey-status.text-error", "cancelled or isn")
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

  # #2247: every passkey added mails the owner, so an account holds at most
  # `Passkey.max_per_account/0` and adds a few an hour. The page says so before
  # the browser prompt, and turns the registration's refusals into sentences.
  describe "passkey limits" do
    defp seed_passkeys(user, count) do
      for n <- 1..count//1 do
        Ash.Seed.seed!(Passkey, %{
          user_id: user.id,
          name: "Device #{n}",
          credential_id: "limit-#{System.unique_integer([:positive])}",
          public_key: :erlang.term_to_binary(%{stub: :cose_key}),
          sign_count: 0
        })
      end
    end

    defp attestation(bytes) do
      %{
        "attestation_object" => Base.url_encode64(bytes, padding: false),
        "client_data_json" => Base.url_encode64(~s({"type":"webauthn.create"}), padding: false),
        "name" => ""
      }
    end

    test "at the cap the add form gives way to a note, and a forced begin is refused", %{
      conn: conn,
      user: user
    } do
      seed_passkeys(user, Passkey.max_per_account())
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      assert has_element?(view, "#passkeys-at-limit", "the most an account can hold")
      refute has_element?(view, "#add-passkey-form")
      # Nothing more can be added here, so no line about mail for adding one.
      refute has_element?(view, "#passkey-added-mail")

      # The handler re-checks: a crafted event gets no challenge.
      render_hook(view, "passkey_begin", %{"name" => ""})

      assert has_element?(view, "#passkey-status.text-error", "Remove one to add another")
      refute has_element?(view, "#passkey-waiting")
      refute_push_event(view, "passkey-register", %{})
    end

    test "below the cap the form is offered", %{conn: conn, user: user} do
      seed_passkeys(user, Passkey.max_per_account() - 1)
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      assert has_element?(view, "#add-passkey-form")
      refute has_element?(view, "#passkeys-at-limit")

      # Beside the screen-lock line: `Passkey.:register` mails the owner every
      # time (#2828).
      assert has_element?(
               view,
               "#passkey-added-mail",
               "We'll email you each time a passkey is added to your account."
             )
    end

    test "a registration the cap refuses says so", %{conn: conn, user: user} do
      seed_passkeys(user, Passkey.max_per_account() - 1)
      {:ok, view, _html} = live(conn, ~p"/editor/settings")
      view |> form("#add-passkey-form", %{"name" => ""}) |> render_submit()

      # Another tab fills the last place while this prompt is open.
      seed_passkeys(user, 1)
      render_hook(view, "passkey_attestation", attestation("limit-race"))

      assert has_element?(view, "#passkey-status.text-error", "Remove one to add another")
      assert has_element?(view, "#passkeys-at-limit")
      assert length(WebAuthn.list(user)) == Passkey.max_per_account()
    end

    test "a registration over the hourly budget says to wait", %{conn: conn, user: user} do
      on_exit(fn -> AccountThrottle.forget_passkey_registrations(user.id) end)

      for _ <- 1..AccountThrottle.defaults()[:passkey_registration_budget],
          do: AccountThrottle.consume_passkey_registration(user.id)

      {:ok, view, _html} = live(conn, ~p"/editor/settings")
      view |> form("#add-passkey-form", %{"name" => ""}) |> render_submit()
      render_hook(view, "passkey_attestation", attestation("over-budget"))

      assert has_element?(view, "#passkey-status.text-error", "several passkeys in a short time")
      assert WebAuthn.list(user) == []
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

    # #1828: the field said nothing about being optional or what it is for,
    # and a save gave no feedback anyone noticed.
    test "explains the field and confirms a save beside the button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/editor/settings")

      assert has_element?(view, "#profile-form label", "Display name (optional)")
      assert has_element?(view, "#profile-form", "Shown as the author of content you publish")
      assert has_element?(view, ~s(#profile-form input[placeholder="e.g. Alex Rivera"]))
      refute has_element?(view, "#profile-saved", "Saved.")

      view |> form("#profile-form", user: %{name: "Grace Hopper"}) |> render_submit()
      assert has_element?(view, "#profile-saved", "Saved.")

      # The next edit takes the confirmation away, so it never vouches for
      # something that has not been saved.
      view |> form("#profile-form", user: %{name: "Grace H."}) |> render_change()
      refute has_element?(view, "#profile-saved", "Saved.")
    end
  end
end
