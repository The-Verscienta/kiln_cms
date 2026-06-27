defmodule KilnCMS.Webhooks.SafeUrlTest do
  # async: false — `with_config` mutates the global SafeUrl Application env
  # (e.g. flipping resolve_dns on), which would otherwise race async tests that
  # read it (the webhook URL validator resolves DNS based on that config).
  use ExUnit.Case, async: false

  alias KilnCMS.Webhooks.SafeUrl

  defp with_config(opts, fun) do
    original = Application.get_env(:kiln_cms, SafeUrl, [])

    try do
      Application.put_env(:kiln_cms, SafeUrl, opts)
      fun.()
    after
      Application.put_env(:kiln_cms, SafeUrl, original)
    end
  end

  describe "validate/1" do
    test "accepts a public HTTPS URL when DNS checks are skipped" do
      with_config([require_https: true, resolve_dns: false], fn ->
        assert :ok = SafeUrl.validate("https://example.com/hooks/kiln")
      end)
    end

    test "rejects non-HTTPS URLs when HTTPS is required" do
      with_config([require_https: true, resolve_dns: false], fn ->
        assert {:error, "must use HTTPS"} = SafeUrl.validate("http://example.com/hook")
      end)
    end

    test "rejects loopback hostnames" do
      with_config([require_https: false, resolve_dns: false], fn ->
        assert {:error, _} = SafeUrl.validate("http://localhost/hook")
        assert {:error, _} = SafeUrl.validate("https://localhost/hook")
      end)
    end

    test "rejects private IPv4 literals" do
      with_config([require_https: false, resolve_dns: false], fn ->
        assert {:error, _} = SafeUrl.validate("http://127.0.0.1/hook")
        assert {:error, _} = SafeUrl.validate("http://192.168.1.10/hook")
        assert {:error, _} = SafeUrl.validate("http://10.0.0.5/hook")
        assert {:error, _} = SafeUrl.validate("http://169.254.169.254/latest/meta-data")
        assert {:error, _} = SafeUrl.validate("http://100.64.0.1/hook")
      end)
    end

    test "rejects internal IPv6 literals" do
      with_config([require_https: false, resolve_dns: false], fn ->
        assert {:error, _} = SafeUrl.validate("https://[fd00::1]/hook")
        assert {:error, _} = SafeUrl.validate("https://[fc00::1]/hook")
        assert {:error, _} = SafeUrl.validate("https://[fe80::1]/hook")
        assert {:error, _} = SafeUrl.validate("https://[::1]/hook")
      end)
    end

    test "rejects IPv4-mapped/compatible IPv6 literals under the IPv4 rules" do
      with_config([require_https: false, resolve_dns: false], fn ->
        assert {:error, _} = SafeUrl.validate("https://[::ffff:169.254.169.254]/hook")
        assert {:error, _} = SafeUrl.validate("https://[::ffff:127.0.0.1]/hook")
      end)
    end

    test "accepts public IPv6 and IPv4 literals" do
      with_config([require_https: false, resolve_dns: false], fn ->
        assert :ok = SafeUrl.validate("https://[2606:2800::1]/hook")
        assert :ok = SafeUrl.validate("http://93.184.216.34/hook")
      end)
    end

    test "rejects .local and .internal hostnames" do
      with_config([require_https: false, resolve_dns: false], fn ->
        assert {:error, _} = SafeUrl.validate("http://printer.local/hook")
        assert {:error, _} = SafeUrl.validate("http://svc.cluster.internal/hook")
      end)
    end

    test "rejects hostnames that resolve to private addresses" do
      with_config([require_https: false, resolve_dns: true], fn ->
        assert {:error, message} = SafeUrl.validate("http://127.0.0.1.nip.io/hook")
        assert message =~ "private" or message =~ "loopback" or message =~ "resolved"
      end)
    end

    # #223: a slow/blocked DNS lookup must fail fast instead of tying up the
    # webhook worker. A zero timeout forces the resolution-timeout path.
    test "fails fast when DNS resolution exceeds the timeout" do
      with_config([require_https: false, resolve_dns: true, dns_timeout_ms: 0], fn ->
        assert {:error, "hostname resolution timed out"} =
                 SafeUrl.validate("https://example.com/hook")
      end)
    end
  end
end
