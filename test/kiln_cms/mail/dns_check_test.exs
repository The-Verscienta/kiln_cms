defmodule KilnCMS.Mail.DnsCheckTest do
  @moduledoc """
  Coverage for the direct-delivery DNS checks and port-25 preflight, driven
  through the DNS/TCP seams with fixture resolvers; one test exercises the
  real `InetTCP` banner path against the local SMTP sink.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Mail.DnsCheck
  alias KilnCMS.Mail.Settings

  defmodule HappyDNS do
    def txt("example.com"), do: ["unrelated", "v=spf1 ip4:203.0.113.9 -all"]
    def txt("sel1._domainkey.example.com"), do: ["v=DKIM1; k=rsa; p=PUB KEY"]
    def txt("_dmarc.example.com"), do: ["v=DMARC1; p=quarantine"]
    def txt(_name), do: []
    def mx(_domain), do: ["mx.probe.test"]
    def ptr({203, 0, 113, 9}), do: {:ok, "mail.example.com"}
    def addresses("mail.example.com"), do: [{203, 0, 113, 9}]
    def addresses(_name), do: []
  end

  defmodule EmptyDNS do
    def txt(_name), do: []
    def mx(_domain), do: []
    def ptr(_address), do: {:error, :nxdomain}
    def addresses(_name), do: []
  end

  defmodule MismatchDNS do
    def txt("example.com"), do: ["v=spf1 include:relay.example -all"]
    def txt("sel1._domainkey.example.com"), do: ["v=DKIM1; k=rsa; p=SOMEONE_ELSES_KEY"]
    def txt(_name), do: []
    def mx(_domain), do: []
    def ptr({203, 0, 113, 9}), do: {:ok, "vps-instance.hosting.example"}
    def addresses("vps-instance.hosting.example"), do: [{203, 0, 113, 9}]
    def addresses(_name), do: []
  end

  defmodule BrokenPtrDNS do
    def txt(_name), do: []
    def mx(_domain), do: []
    def ptr({203, 0, 113, 9}), do: {:ok, "mail.example.com"}
    # Forward lookup does not round-trip.
    def addresses(_name), do: [{198, 51, 100, 1}]
  end

  defmodule PrefixSpfDNS do
    def txt("example.com"), do: ["v=spf1 ip4:203.0.113.90 -all"]
    def txt(_name), do: []
    def mx(_domain), do: []
    def ptr(_address), do: {:error, :nxdomain}
    def addresses(_name), do: []
  end

  defmodule MixedCasePtrDNS do
    def txt(_name), do: []
    def mx(_domain), do: []
    def ptr({203, 0, 113, 9}), do: {:ok, "Mail.Example.COM"}
    def addresses("Mail.Example.COM"), do: [{203, 0, 113, 9}]
    def addresses(_name), do: []
  end

  defmodule ParentDmarcDNS do
    def txt("_dmarc.example.com"), do: ["v=DMARC1; p=quarantine"]
    def txt(_name), do: []
    def mx(_domain), do: []
    def ptr(_address), do: {:error, :nxdomain}
    def addresses(_name), do: []
  end

  defmodule OpenTCP do
    def banner(_host, 25, _timeout), do: {:ok, "220 mx.probe.test ESMTP ready\r\n"}
  end

  defmodule BlockedTCP do
    def banner(_host, 25, _timeout), do: {:error, :timeout}
  end

  defmodule WeirdTCP do
    def banner(_host, 25, _timeout), do: {:ok, "554 go away\r\n"}
  end

  defp settings(attrs \\ []) do
    struct!(
      %Settings{dkim_selector: "sel1", dkim_public_key: "PUBKEY", server_ip: "203.0.113.9"},
      attrs
    )
  end

  defp run(settings, dns),
    do: DnsCheck.run(settings, domain: "example.com", dns: dns, helo_host: "mail.example.com")

  describe "run/2" do
    test "all green when every record is published correctly" do
      results = run(settings(), HappyDNS)

      assert %{status: :ok, found: "v=spf1 ip4:203.0.113.9 -all"} = results.spf
      # Whitespace in the published p= value (chunk splits) is tolerated.
      assert %{status: :ok} = results.dkim
      assert %{status: :ok} = results.dmarc
      assert %{status: :ok, found: "mail.example.com"} = results.ptr
    end

    test "absent records fail (SPF/DKIM/PTR) or warn (DMARC) with expected values" do
      results = run(settings(), EmptyDNS)

      assert %{status: :fail, expected: "v=spf1 ip4:203.0.113.9 -all"} = results.spf
      assert %{status: :fail, expected: "v=DKIM1; k=rsa; p=PUBKEY"} = results.dkim
      assert %{status: :warn} = results.dmarc
      assert %{status: :fail} = results.ptr
      assert results.ptr.detail =~ "hosting provider"
    end

    test "presence-level honesty: unconfirmed SPF and stale DKIM keys" do
      results = run(settings(), MismatchDNS)

      assert %{status: :warn} = results.spf
      assert results.spf.detail =~ "includes/redirects"

      assert %{status: :fail} = results.dkim
      assert results.dkim.detail =~ "different public key"

      # PTR round-trips but doesn't match HELO — warn, not fail.
      assert %{status: :warn, found: "vps-instance.hosting.example"} = results.ptr
      assert results.ptr.detail =~ "MAIL_HELO_HOST"
    end

    test "a PTR that doesn't round-trip fails" do
      results = run(settings(), BrokenPtrDNS)

      assert %{status: :fail} = results.ptr
      assert results.ptr.detail =~ "does not resolve back"
    end

    test "missing prerequisites skip or downgrade instead of guessing" do
      results = run(settings(server_ip: nil), HappyDNS)
      assert %{status: :warn} = results.spf
      assert results.spf.detail =~ "set the server IP"
      assert %{status: :skip} = results.ptr

      results = run(settings(dkim_public_key: nil), HappyDNS)
      assert %{status: :skip} = results.dkim

      results = DnsCheck.run(settings(), domain: nil, dns: HappyDNS)
      assert Enum.all?(Map.values(results), &(&1.status == :skip))
    end

    test "SPF only passes on an exact IP mechanism, not a prefix substring" do
      # server_ip 203.0.113.9, but the record authorizes 203.0.113.90 — a bare
      # substring match would report this covered (false green).
      assert %{status: :warn} = run(settings(), PrefixSpfDNS).spf
    end

    test "PTR that differs from HELO only by letter case is not warned (RFC 4343)" do
      # helo_host is "mail.example.com"; PTR is "Mail.Example.COM" —
      # case-folded they match → :ok, not a spurious :warn.
      assert %{status: :ok} = run(settings(), MixedCasePtrDNS).ptr
    end

    test "DMARC is inherited from the organizational (parent) domain" do
      # From cms@mail.example.com: no record at _dmarc.mail.example.com, but a
      # policy exists at the parent _dmarc.example.com (RFC 7489 §3.2).
      result = DnsCheck.run(settings(), domain: "mail.example.com", dns: ParentDmarcDNS).dmarc

      assert %{status: :ok} = result
      assert result.detail =~ "organizational domain example.com"
    end
  end

  describe "expected_records/2" do
    test "lists the four records with real values when configured" do
      records =
        DnsCheck.expected_records(settings(),
          domain: "example.com",
          helo_host: "mail.example.com"
        )

      assert [spf, dkim, dmarc, ptr] = records
      assert %{type: "TXT", host: "example.com", value: "v=spf1 ip4:203.0.113.9 -all"} = spf

      assert %{
               type: "TXT",
               host: "sel1._domainkey.example.com",
               value: "v=DKIM1; k=rsa; p=PUBKEY"
             } =
               dkim

      assert %{type: "TXT", host: "_dmarc.example.com"} = dmarc
      assert dmarc.value =~ "v=DMARC1"
      assert %{type: "PTR", host: "203.0.113.9", value: "mail.example.com"} = ptr
    end

    test "uses placeholders before anything is configured" do
      records =
        DnsCheck.expected_records(
          settings(dkim_selector: nil, dkim_public_key: nil, server_ip: nil),
          domain: "example.com",
          helo_host: nil
        )

      assert Enum.any?(records, &(&1.value =~ "<server-ip>"))
      assert Enum.any?(records, &(&1.host =~ "<selector>"))
    end
  end

  describe "check_port25/1" do
    test "reachable when a probe MX answers 220" do
      assert %{status: :ok} = DnsCheck.check_port25(dns: HappyDNS, tcp: OpenTCP)
    end

    test "blocked port fails with relay guidance" do
      result = DnsCheck.check_port25(dns: HappyDNS, tcp: BlockedTCP)

      assert result.status == :fail
      assert result.detail =~ "blocks outbound SMTP"
      assert result.detail =~ "MAIL_MODE=smtp"
      assert result.detail =~ ":timeout"
    end

    test "a received non-220 banner warns (port open, reputation) rather than failing" do
      # WeirdTCP connects and returns "554 ..." — the port is demonstrably open,
      # so this must not be reported as a blocked port.
      result = DnsCheck.check_port25(dns: HappyDNS, tcp: WeirdTCP)
      assert result.status == :warn
      assert result.detail =~ "reachable"
      assert result.detail =~ "reputation"
      refute result.detail =~ "blocks outbound"
    end

    test "no reachable MX counts as failure" do
      assert %{status: :fail} = DnsCheck.check_port25(dns: EmptyDNS, tcp: OpenTCP)
    end
  end

  test "InetTCP reads a real banner from an SMTP server and quits cleanly" do
    {sink_name, port} = KilnCMS.SMTPSink.start(self())
    on_exit(fn -> :gen_smtp_server.stop(sink_name) end)

    assert {:ok, "220" <> _rest} = DnsCheck.InetTCP.banner("127.0.0.1", port, 2_000)
  end
end
