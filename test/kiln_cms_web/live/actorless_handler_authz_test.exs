defmodule KilnCMSWeb.ActorlessHandlerAuthzTest do
  @moduledoc """
  The handlers whose privileged call takes no actor (#1166).

  Every other privileged `handle_event/3` in the console funnels into an Ash
  action carrying the actor, so a mistake in the mount guard is still caught by
  a policy. These six do not: `Newsletter.send_as_newsletter/2` writes with
  `authorize?: false`, `Mail.deliver_now/1` is a bare `Mailer.deliver/1`,
  `DnsCheck.run/1` and `check_port25/0` take no arguments about who is asking,
  `Links.SweepWorker.enqueue/1` takes an org id, `Billing.verify_credentials/0`
  takes nothing, and `ReleasePreview.sign/1` takes a struct. For them the guard
  *is* the authorization — and a mount guard is evaluated once, so a role
  revoked mid-session would otherwise hold for the life of the socket.

  Called directly rather than through `live/2`: where the mount refuses there is
  no socket to push an event down, and the question here is what each handler
  does on its own. That is the same reason the mount guard is not enough.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.User

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "authz-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # The minimum a tier check reads: `platform_admin?/1` looks only at
  # `current_user`, `effective_tier/1` also resolves the request's org. `flash`
  # is there because some refusals say so rather than returning silently.
  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{__changed__: %{}, flash: %{}, current_org: KilnCMS.Accounts.default_org()},
          assigns
        )
    }
  end

  describe "NewsletterLive send" do
    # The worst of the set: irreversible. A backup can be deleted; an email
    # cannot be unsent.
    test "an editor's forged send enqueues nothing" do
      socket = socket(%{current_user: user(:editor), actor: user(:editor), posts: []})

      assert {:noreply, ^socket} =
               KilnCMSWeb.NewsletterLive.handle_event("send", %{"send" => %{}}, socket)

      assert KilnCMS.Repo.all(Oban.Job) == []
    end
  end

  describe "MailSettingsLive" do
    # The recipient is client input and the send is signed by this deployment's
    # DKIM key, so this is a send primitive pointed at any address a socket
    # names.
    test "an editor's forged send_test delivers nothing" do
      socket = socket(%{current_user: user(:editor), sending_test?: false, test_to: nil})

      assert {:noreply, ^socket} =
               KilnCMSWeb.MailSettingsLive.handle_event(
                 "send_test",
                 %{"test" => %{"to" => "somebody@example.com"}},
                 socket
               )

      refute_email_sent()
    end

    test "an editor's forged verify starts no DNS run" do
      socket = socket(%{current_user: user(:editor), verifying?: false, settings: nil})

      assert {:noreply, ^socket} =
               KilnCMSWeb.MailSettingsLive.handle_event("verify", %{}, socket)
    end

    test "an editor's forged preflight starts no port-25 dial" do
      socket = socket(%{current_user: user(:editor), preflighting?: false})

      assert {:noreply, ^socket} =
               KilnCMSWeb.MailSettingsLive.handle_event("preflight", %{}, socket)
    end

    # A per-org admin is not a platform admin, and mail settings are
    # instance-wide. This is the case that separates the two questions.
    test "an org admin who is not a platform admin is refused too" do
      person = user(:editor)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        user_id: person.id,
        organization_id: KilnCMS.Accounts.default_org_id(),
        role: :admin
      })

      assert KilnCMS.Accounts.Scoping.effective_tier(person, KilnCMS.Accounts.default_org_id()) ==
               :admin

      socket = socket(%{current_user: person, sending_test?: false, test_to: nil})

      assert {:noreply, ^socket} =
               KilnCMSWeb.MailSettingsLive.handle_event(
                 "send_test",
                 %{"test" => %{"to" => "somebody@example.com"}},
                 socket
               )

      refute_email_sent()
    end
  end

  describe "LinkReportLive check_now" do
    # The purest instance: this page is on `:editor_routes`, so mount never
    # refuses — a mount-time `@admin?` boolean was the whole gate.
    test "an editor's forged check_now enqueues no sweep" do
      person = user(:editor)
      socket = socket(%{current_user: person, actor: person, admin?: true})

      assert {:noreply, %{assigns: %{}}} =
               KilnCMSWeb.LinkReportLive.handle_event("check_now", %{}, socket)

      assert KilnCMS.Repo.all(Oban.Job) == []
    end

    # And the stale assign is no longer what decides. `admin?: true` is exactly
    # what a socket carries after its holder's access was revoked.
    test "a stale admin? assign does not authorize the enqueue" do
      person = user(:editor)
      socket = socket(%{current_user: person, actor: person, admin?: true})

      KilnCMSWeb.LinkReportLive.handle_event("check_now", %{}, socket)

      assert KilnCMS.Repo.all(Oban.Job) == []
    end
  end

  describe "BillingLive verify" do
    test "an editor's forged verify calls no provider" do
      socket = socket(%{current_user: user(:editor), verifying?: false})

      assert {:noreply, ^socket} =
               KilnCMSWeb.BillingLive.handle_event("verify", %{}, socket)
    end
  end

  describe "ReleaseLive share_preview" do
    # Deliberately still an editor action — previewing is what the feature is
    # for. What changed is that the read is re-verified at mint time rather than
    # trusted from a struct fetched at mount, so a link cannot be minted for a
    # release the actor can no longer read.
    test "a release the actor cannot read mints no link" do
      person = user(:editor)

      socket =
        socket(%{
          current_user: person,
          actor: person,
          release: %{id: Ash.UUID.generate()},
          preview_url: nil
        })

      assert {:noreply, result} =
               KilnCMSWeb.ReleaseLive.handle_event("share_preview", %{}, socket)

      assert is_nil(result.assigns[:preview_url])
    end
  end
end
