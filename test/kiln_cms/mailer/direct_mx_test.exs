defmodule KilnCMS.Mailer.DirectMXTest do
  @moduledoc """
  Coverage for the direct-to-MX Swoosh adapter: per-domain fan-out and SMTP
  config shape (via an injected capture adapter), failure propagation, and one
  real-socket delivery to a local gen_smtp sink server standing in for a
  recipient MX.
  """
  # DataCase (not plain ExUnit.Case): the adapter resolves DKIM options via
  # KilnCMS.Mail.dkim_config/0, which reads the mail-settings row — the test
  # process needs a sandboxed DB connection even when no row exists.
  use KilnCMS.DataCase, async: true
  # `except: from/2` — DataCase imports Ecto.Query.from/2.
  import Swoosh.Email, except: [from: 2]

  alias KilnCMS.Mailer.DirectMX

  # Records every (email, config) the adapter would hand to
  # Swoosh.Adapters.SMTP, without touching the network.
  defmodule CaptureSMTP do
    def deliver(email, config) do
      send(config[:test_pid], {:smtp_call, email, config})
      {:ok, "250 queued"}
    end
  end

  defmodule FailFor do
    def deliver(email, config) do
      [{_name, address} | _] = email.to ++ email.cc ++ email.bcc

      if String.ends_with?(address, config[:fail_domain]) do
        {:error, {:permanent_failure, ~c"mx", "550 no"}}
      else
        send(config[:test_pid], {:delivered, address})
        {:ok, "250 queued"}
      end
    end
  end

  defp email do
    new()
    |> Swoosh.Email.from({"KilnCMS", "cms@example.com"})
    |> to("one@alpha.test")
    |> subject("Hello")
    |> html_body("<p>Hi</p>")
    |> text_body("Hi")
  end

  defp capture_config(overrides \\ []) do
    Keyword.merge(
      [smtp_adapter: CaptureSMTP, test_pid: self(), hostname: "kiln.example.com"],
      overrides
    )
  end

  describe "per-domain fan-out (capture adapter)" do
    test "groups recipients by domain, keeping to/cc fields truthful" do
      sent =
        email()
        |> to({"Two", "two@beta.test"})
        |> cc("three@alpha.test")

      assert {:ok, %{receipts: [_, _]}} = DirectMX.deliver(sent, capture_config())

      assert_receive {:smtp_call, beta_email, beta_config}
      assert beta_email.to == [{"Two", "two@beta.test"}]
      assert beta_email.cc == []
      assert beta_config[:relay] == "beta.test"

      assert_receive {:smtp_call, alpha_email, alpha_config}
      assert alpha_email.to == [{"", "one@alpha.test"}]
      assert alpha_email.cc == [{"", "three@alpha.test"}]
      assert alpha_config[:relay] == "alpha.test"
    end

    test "builds MTA-shaped SMTP config: port 25, MX lookup, no auth, opportunistic TLS" do
      assert {:ok, _} = DirectMX.deliver(email(), capture_config())

      assert_receive {:smtp_call, _email, config}
      assert config[:relay] == "alpha.test"
      assert config[:port] == 25
      assert config[:no_mx_lookups] == false
      assert config[:auth] == :never
      assert config[:tls] == :if_available
      assert config[:tls_options][:verify] == :verify_none
      assert config[:sockopts] == [:inet]
      assert config[:hostname] == "kiln.example.com"
      # No DKIM options until a key is configured (Phase 3).
      refute Keyword.has_key?(config, :dkim)
    end

    test "passes dkim options through when provided" do
      dkim = [s: "kiln", d: "example.com", private_key: {:pem_plain, "fake"}]

      assert {:ok, _} = DirectMX.deliver(email(), capture_config(dkim: dkim))

      assert_receive {:smtp_call, _email, config}
      assert config[:dkim] == dkim
    end

    test "a failing domain fails the delivery" do
      sent = email() |> to("two@beta.test")

      assert {:error, {:permanent_failure, _host, _msg}} =
               DirectMX.deliver(sent,
                 smtp_adapter: FailFor,
                 test_pid: self(),
                 fail_domain: "alpha.test"
               )
    end
  end

  test "delivers a real message over a socket to the recipient's SMTP server" do
    {sink_name, port} = KilnCMS.SMTPSink.start(self())
    on_exit(fn -> :gen_smtp_server.stop(sink_name) end)

    assert {:ok, %{receipts: [receipt]}} =
             DirectMX.deliver(email(),
               relay_override: "127.0.0.1",
               port: port,
               no_mx_lookups: true,
               tls: :never,
               hostname: "kiln.example.com"
             )

    assert receipt =~ "queued"

    assert_receive {:smtp_sink, from, to, data}, 2_000
    assert from =~ "cms@example.com"
    assert to == ["one@alpha.test"]
    assert data =~ "Subject: Hello"
    assert data =~ "Hi"
  end
end
