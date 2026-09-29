defmodule KilnCMS.Mail.SystemActorAuthorizationTest do
  @moduledoc """
  #1659 batch 6: the mail pipeline runs as `KilnCMS.Mail.system/0` rather
  than `authorize?: false`, for the settings singleton and both suppression
  lists.

  Every grant is paired with a refusal. The two reads that decide what goes
  out are tested with the grant taken away (`Mail.with_actor(nil, ...)`):

    * a suppression lookup that cannot be read must never answer "not
      suppressed", which would resume mail to every address that ever hard
      bounced. `suppressed?/2` raises, and `enqueue!/2` drops the recipient
      and logs;
    * a settings read that cannot be read must never answer `nil` ("not set
      up yet"), which `dkim_config/0` reads as "no DKIM key" and sends
      unsigned.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog
  import Swoosh.Email, except: [from: 2]

  alias KilnCMS.Mail
  alias KilnCMS.Mail.DeliveryWorker

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sab6-mail-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp email(to) do
    new()
    |> Swoosh.Email.from({"KilnCMS", "cms@operator.example"})
    |> to(to)
    |> subject("Hello")
    |> text_body("Hi")
  end

  describe "Mail.Settings" do
    test "the system actor reads the singleton and inserts it on first use" do
      system = Mail.system()

      assert {:ok, settings} = Mail.init_settings(%{}, actor: system)

      assert [read] = Mail.list_settings!(actor: system, authorize_with: :error)
      assert read.id == settings.id
      assert Mail.get_settings().id == settings.id
    end

    test "...and may not change the key or the server IP" do
      system = Mail.system()
      settings = Mail.ensure_settings!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.set_mail_server_ip(settings, %{server_ip: "192.0.2.1"}, actor: system)

      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.record_mail_verification(settings, %{verification_results: %{}},
                 actor: system
               )

      refute Ash.can?({settings, :generate_dkim}, system)
      refute Ash.can?({settings, :rotate_dkim}, system)
    end

    test "with the grant gone the read raises instead of answering \"not set up\"" do
      Mail.ensure_settings!()

      assert_raise Ash.Error.Forbidden, fn ->
        Mail.with_actor(nil, fn -> Mail.get_settings() end)
      end
    end
  end

  describe "Mail.SuppressedRecipient (instance-wide)" do
    test "the system actor records a bounce and looks it up" do
      system = Mail.system()

      assert {:ok, _} = Mail.suppress_recipient(%{email: "gone@example.com"}, actor: system)

      assert %{} =
               Mail.get_suppressed_recipient!("gone@example.com",
                 actor: system,
                 authorize_with: :error
               )

      assert Mail.suppressed?("gone@example.com")
    end

    test "...and may not clear one" do
      system = Mail.system()
      {:ok, entry} = Mail.suppress_recipient(%{email: "gone@example.com"}, actor: system)

      assert {:error, %Ash.Error.Forbidden{}} = Mail.unsuppress_recipient(entry, actor: system)
      assert Mail.suppressed?("gone@example.com")
    end
  end

  describe "Mail.SiteSuppressedRecipient (per site)" do
    setup do
      %{site: KilnCMS.OrgFixtures.org("sab6-mail")}
    end

    test "the system actor records a bounce on the site's list and looks it up", %{site: site} do
      system = Mail.system()

      assert {:ok, _} =
               Mail.suppress_site_recipient(%{email: "gone@example.com"},
                 actor: system,
                 tenant: site
               )

      assert %{} =
               Mail.get_site_suppressed_recipient!("gone@example.com",
                 actor: system,
                 authorize_with: :error,
                 tenant: site
               )

      assert Mail.suppressed?("gone@example.com", org_id: site.id)
      refute Mail.suppressed?("gone@example.com")
    end

    test "...and may not clear one; nor may a platform admin add one", %{site: site} do
      system = Mail.system()

      {:ok, entry} =
        Mail.suppress_site_recipient(%{email: "gone@example.com"}, actor: system, tenant: site)

      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.unsuppress_site_recipient(entry, actor: system, tenant: site)

      assert {:error, %Ash.Error.Forbidden{}} =
               Mail.suppress_site_recipient(%{email: "other@example.com"},
                 actor: user(:admin),
                 tenant: site
               )
    end
  end

  describe "fail closed" do
    test "with the grant gone a lookup raises instead of answering \"not suppressed\"" do
      assert_raise Ash.Error.Forbidden, fn ->
        Mail.with_actor(nil, fn -> Mail.suppressed?("anyone@example.com") end)
      end
    end

    test "enqueue! drops a recipient it cannot check, and logs it" do
      log =
        capture_log(fn ->
          assert :ok =
                   Mail.with_actor(nil, fn -> Mail.enqueue!(email("anyone@example.com")) end)
        end)

      assert log =~ "Suppression list unreadable, not sending to one recipient"
      refute log =~ "anyone@example.com"
      refute_enqueued(worker: DeliveryWorker)
    end

    test "with the grant in place the same recipient is queued" do
      assert :ok = Mail.enqueue!(email("anyone@example.com"))
      assert_enqueued(worker: DeliveryWorker)
    end
  end
end
