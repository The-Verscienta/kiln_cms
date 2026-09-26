defmodule KilnCMS.Mail.SiteRelayTest do
  @moduledoc """
  A site's own SMTP relay (#1322): the row (`KilnCMS.CMS.SiteMailRelay`), the
  resolver that decides which relay a site's mail uses (`KilnCMS.Mail.SiteRelay`),
  and the mail pipeline's use of it (`KilnCMS.Mail`).

  What each group pins, because each is a way this could quietly go wrong:

    * **precedence** — a site row switched on wins; none, or switched off, is
      the operator's relay; and one site's row never touches another site.
    * **the connection** — built from the row alone, with the operator's
      mailer config nowhere underneath; TLS verified; MX lookup off.
    * **fail direction** — a row that can't be used holds the mail; it never
      falls back to the operator's relay.
    * **the tenant boundary** — a private host is refused at save and at send,
      and a site relay's hard reject never suppresses an address instance-wide.
    * **the password** — encrypted, kept on a blank save, cleared with the
      username.
  """
  use KilnCMS.DataCase, async: true

  import Swoosh.Email, except: [from: 2]
  import Swoosh.TestAssertions

  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.CMS.SiteMailRelay
  alias KilnCMS.Keys.Vault
  alias KilnCMS.Mail
  alias KilnCMS.Mail.SiteRelay

  defmodule PermanentFailureAdapter do
    use Swoosh.Adapter

    # A RCPT TO reject arrives under `:send` (the mail transaction), never
    # `:no_more_hosts` (the session, which ends before any address is sent) —
    # so this is what a relay refusing *the recipient* actually looks like.
    # The distinction is load-bearing since #1575: a session failure is the
    # relay refusing us, and retries rather than cancelling.
    def deliver(_email, _config),
      do:
        {:error,
         {:send,
          {:permanent_failure, ~c"smtp.example.com", "550 5.1.1 Recipient address rejected"}}}
  end

  defmodule ConnectionFailureAdapter do
    use Swoosh.Adapter

    def deliver(_email, _config),
      do:
        {:error,
         {:retries_exceeded, {:network_failure, ~c"smtp.example.com", {:error, :econnrefused}}}}
  end

  setup do
    %{org: KilnCMS.OrgFixtures.org("relay"), other: KilnCMS.OrgFixtures.org("relay-other")}
  end

  defp relay!(org, attrs \\ %{}) do
    %{
      host: "smtp.example.com",
      port: 587,
      username: "apikey",
      password: "s3cret-pass",
      from_email: "news@site.example"
    }
    |> Map.merge(attrs)
    |> CMS.save_site_mail_relay!(tenant: org, authorize?: false)
  end

  defp email do
    new()
    |> Swoosh.Email.from({"KilnCMS", "cms@operator.example"})
    |> to("reader@example.com")
    |> subject("Hello")
    |> text_body("Hi")
  end

  # Writes a column the actions never would — a host that validated once and a
  # ciphertext from before a key rotation are both states the row can be in.
  defp force_column!(row, column, value) do
    {1, _} =
      KilnCMS.Repo.update_all(
        from(r in "site_mail_relays", where: r.id == type(^row.id, :binary_id)),
        set: [{column, value}]
      )
  end

  describe "precedence" do
    test "no site is the operator's relay", _ctx do
      assert {:operator, %Swoosh.Email{}} = SiteRelay.route(email(), nil)
    end

    test "a site with no row is the operator's relay", %{org: org} do
      assert :operator = SiteRelay.resolve(org.id)
    end

    test "a row switched off is the operator's relay", %{org: org} do
      relay!(org, %{enabled: false})
      assert :operator = SiteRelay.resolve(org.id)
    end

    test "a row switched on is the site's relay and From", %{org: org} do
      relay!(org, %{from_name: "Site News"})

      assert {:site, config, {"Site News", "news@site.example"}} = SiteRelay.resolve(org.id)
      assert config[:relay] == "smtp.example.com"
      assert config[:port] == 587
    end

    test "one site's row never reaches another site", %{org: org, other: other} do
      relay!(org)
      assert :operator = SiteRelay.resolve(other.id)
    end

    test "a blank From name is the site's own name, not the operator's", %{org: org} do
      relay!(org)
      site_name = KilnCMS.Branding.for_org(org.id).site_name

      assert {:site, _config, {^site_name, "news@site.example"}} = SiteRelay.resolve(org.id)
    end
  end

  describe "the connection" do
    test "is built from the row alone — no operator key underneath", %{org: org} do
      relay!(org)
      {:site, config, _from} = SiteRelay.resolve(org.id)

      assert Keyword.keys(config) |> Enum.sort() ==
               Enum.sort([
                 :adapter,
                 :relay,
                 :port,
                 :no_mx_lookups,
                 :auth,
                 :username,
                 :password,
                 :ssl,
                 :tls,
                 :tls_options,
                 :sockopts
               ])

      assert config[:username] == "apikey"
      assert config[:password] == "s3cret-pass"
      assert config[:auth] == :always
    end

    test "turns gen_smtp's MX lookup off — it would re-resolve outside the pin", %{org: org} do
      relay!(org)
      {:site, config, _from} = SiteRelay.resolve(org.id)
      assert config[:no_mx_lookups] == true
    end

    test "STARTTLS is required and the certificate verified against the typed name",
         %{org: org} do
      relay!(org)
      {:site, config, _from} = SiteRelay.resolve(org.id)

      assert config[:tls] == :always
      assert config[:ssl] == false
      assert config[:tls_options][:verify] == :verify_peer
      assert config[:tls_options][:server_name_indication] == ~c"smtp.example.com"
      assert config[:tls_options][:customize_hostname_check][:match_fun]
    end

    test "implicit TLS carries the same verification on the socket", %{org: org} do
      relay!(org, %{security: :tls, port: 465})
      {:site, config, _from} = SiteRelay.resolve(org.id)

      assert config[:ssl] == true
      assert config[:sockopts][:verify] == :verify_peer
      assert config[:sockopts][:server_name_indication] == ~c"smtp.example.com"
    end

    test "no username sends no credentials at all", %{org: org} do
      relay!(org, %{username: nil, password: nil})
      {:site, config, _from} = SiteRelay.resolve(org.id)

      assert config[:auth] == :never
      refute Keyword.has_key?(config, :username)
      refute Keyword.has_key?(config, :password)
    end
  end

  describe "fail direction — hold, never fall back" do
    test "an undecryptable password holds the mail", %{org: org} do
      row = relay!(org)
      # What a SECRET_KEY_BASE rotation leaves behind.
      force_column!(row, :password_encrypted, :crypto.strong_rand_bytes(48))

      assert {:error, :credentials_unreadable} = SiteRelay.resolve(org.id)

      assert_raise Mail.TransientDeliveryError, ~r/holding/, fn ->
        Mail.deliver_for_worker(email(), org_id: org.id)
      end

      refute_received {:email, _operator_delivery}
      refute_received {:site_relay_email, _email, _config}
    end

    test "a host that now resolves somewhere private holds the mail", %{org: org} do
      row = relay!(org)
      force_column!(row, :host, "10.0.0.25")

      assert {:error, {:host_refused, _message}} = SiteRelay.resolve(org.id)

      assert_raise Mail.TransientDeliveryError, fn ->
        Mail.deliver_for_worker(email(), org_id: org.id)
      end

      refute_received {:email, _operator_delivery}
    end

    test "a row that can't be read holds the mail", _ctx do
      # Not a uuid: the tenant filter itself fails, which is the read failing
      # rather than finding nothing.
      assert {:error, :unavailable} = SiteRelay.resolve("not-an-org-id")
    end

    test "the page's decryptability check agrees with the resolver", %{org: org} do
      row = relay!(org)
      assert SiteRelay.password_readable?(row)

      force_column!(row, :password_encrypted, :crypto.strong_rand_bytes(48))
      {:ok, [row]} = CMS.list_site_mail_relay(tenant: org, authorize?: false)
      refute SiteRelay.password_readable?(row)
    end
  end

  describe "the mail pipeline" do
    test "site mail goes through the site's relay, from the site's address", %{org: org} do
      relay!(org, %{from_name: "Site News"})

      assert :ok =
               email()
               |> Mail.ensure_message_id("job-1")
               |> Mail.deliver_for_worker(org_id: org.id)

      assert_received {:site_relay_email, sent, config}
      assert sent.from == {"Site News", "news@site.example"}
      # The Message-ID keeps its stable local part and moves to the From domain.
      assert sent.headers["Message-ID"] == "<job-1@site.example>"
      assert config[:relay] == "smtp.example.com"
      assert_no_email_sent()
    end

    test "mail with no site stays on the operator's relay", %{org: org} do
      relay!(org)

      assert :ok = Mail.deliver_for_worker(email())

      assert_email_sent(subject: "Hello")
      refute_received {:site_relay_email, _email, _config}
    end

    test "enqueue!/2 carries the site to the delivery job", %{org: org} do
      relay!(org)

      Oban.Testing.with_testing_mode(:manual, fn ->
        :ok = Mail.enqueue!(email(), org_id: org.id)

        assert [%Oban.Job{args: %{"org_id" => org_id} = args}] =
                 all_enqueued(worker: Mail.DeliveryWorker)

        assert org_id == org.id
        assert :ok = perform_job(Mail.DeliveryWorker, args)
      end)

      assert_received {:site_relay_email, %{from: {_name, "news@site.example"}}, _config}
    end

    test "a site relay's hard reject cancels without suppressing the address instance-wide",
         %{org: org} do
      relay!(org)

      assert {:cancel, _reason} =
               Mail.deliver_for_worker(email(),
                 org_id: org.id,
                 adapter: PermanentFailureAdapter
               )

      # The reject names the recipient, so on the operator's relay this would
      # suppress the address (#1575). The instance-wide list stops account mail
      # too, and a relay the site chose must not be able to write to it — the
      # site's word goes on the site's own list (#1562, `SiteSuppressionTest`).
      refute Mail.suppressed?("reader@example.com")
      assert Mail.suppressed?("reader@example.com", org_id: org.id)
    end

    test "a site relay that's down retries without the operator's outage alert", %{org: org} do
      relay!(org)

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:kiln_cms, :mail, :relay_unreachable]])

      on_exit(fn -> :telemetry.detach(ref) end)

      assert_raise Mail.TransientDeliveryError, fn ->
        Mail.deliver_for_worker(email(), org_id: org.id, adapter: ConnectionFailureAdapter)
      end

      refute_received {[:kiln_cms, :mail, :relay_unreachable], ^ref, _measure, _meta}
    end

    test "deliver_now/2 answers an unusable site relay as an error, not a raise", %{org: org} do
      row = relay!(org)
      force_column!(row, :password_encrypted, :crypto.strong_rand_bytes(48))

      assert {:error, {:site_relay, :credentials_unreadable}} =
               Mail.deliver_now(email(), org_id: org.id)
    end
  end

  describe "the row" do
    test "the password is stored encrypted, never as given", %{org: org} do
      row = relay!(org)

      assert is_binary(row.password_encrypted)
      refute row.password_encrypted =~ "s3cret-pass"
      assert {:ok, "s3cret-pass"} = Vault.decrypt(row.password_encrypted)
    end

    test "a blank password on update keeps the stored one", %{org: org} do
      row = relay!(org)

      updated =
        CMS.update_site_mail_relay!(row, %{port: 2525, password: ""},
          tenant: org,
          authorize?: false
        )

      assert updated.port == 2525
      assert {:ok, "s3cret-pass"} = Vault.decrypt(updated.password_encrypted)
    end

    test "a new password replaces it", %{org: org} do
      row = relay!(org)

      updated =
        CMS.update_site_mail_relay!(row, %{password: "rotated"}, tenant: org, authorize?: false)

      assert {:ok, "rotated"} = Vault.decrypt(updated.password_encrypted)
    end

    test "clearing the username clears the password", %{org: org} do
      row = relay!(org)

      updated =
        CMS.update_site_mail_relay!(row, %{username: nil}, tenant: org, authorize?: false)

      assert is_nil(updated.password_encrypted)
    end

    test "a username with no password given or stored is refused", %{org: org} do
      assert {:error, error} =
               CMS.save_site_mail_relay(
                 %{host: "smtp.example.com", from_email: "a@site.example", username: "u"},
                 tenant: org,
                 authorize?: false
               )

      assert Exception.message(error) =~ "required when a username is set"
    end

    test "switched on, it needs a host and a From address", %{org: org} do
      assert {:error, error} = CMS.save_site_mail_relay(%{}, tenant: org, authorize?: false)
      message = Exception.message(error)
      assert message =~ "host"
      assert message =~ "from_email"
    end

    test "switched off, it may be saved half-filled", %{org: org} do
      assert {:ok, _row} =
               CMS.save_site_mail_relay(%{enabled: false}, tenant: org, authorize?: false)
    end

    for host <- ["10.1.2.3", "127.0.0.1", "169.254.169.254", "localhost", "relay.internal"] do
      test "refuses the private host #{host} at save", %{org: org} do
        assert {:error, error} =
                 CMS.save_site_mail_relay(
                   %{host: unquote(host), from_email: "a@site.example"},
                   tenant: org,
                   authorize?: false
                 )

        assert Exception.message(error) =~ "host"
      end
    end

    test "refuses host:port — the port is its own field", %{org: org} do
      assert {:error, error} =
               CMS.save_site_mail_relay(
                 %{host: "smtp.example.com:587", from_email: "a@site.example"},
                 tenant: org,
                 authorize?: false
               )

      assert Exception.message(error) =~ "without a port"
    end

    test "refuses a From name that would start a second header", %{org: org} do
      assert {:error, error} =
               CMS.save_site_mail_relay(
                 %{
                   host: "smtp.example.com",
                   from_email: "a@site.example",
                   from_name: "News\r\nBcc: victim@example.com"
                 },
                 tenant: org,
                 authorize?: false
               )

      assert Exception.message(error) =~ "one line"
    end

    test "the ciphertext is left out of inspect output, so out of logs", %{org: org} do
      row = relay!(org)
      refute inspect(row) =~ "password_encrypted"
    end

    test "is read by admins only — it names the site's mail account" do
      assert SiteMailRelay.__kiln_org_settings__().read == :admin
    end
  end
end
