defmodule KilnCMS.Backups.Destination.HostPolicyTest do
  @moduledoc """
  The host rule Kiln's network destinations share (#2221, #2222, ADR 0069):
  which addresses no listing opens, which an exact-name listing opens, and
  how a refusal names the adapter's own variable.

  `async: false`: the pinning cases turn on `KilnCMS.Webhooks.SafeUrl`'s DNS
  resolution with a stub resolver, which is application env (VM-global).
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Backups.Destination.HostPolicy

  @s3 [env: "BACKUP_S3_PRIVATE_HOSTS", noun: "the endpoint"]
  @sftp [env: "BACKUP_SFTP_PRIVATE_HOSTS", noun: "the host"]

  # Addresses no listing opens.
  @never [
    {169, 254, 169, 254},
    {169, 254, 0, 1},
    {0xFE80, 0, 0, 0, 0, 0, 0, 1},
    {0xFEBF, 0, 0, 0, 0, 0, 0, 1},
    {0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254},
    {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE},
    {0, 0, 0, 0, 0, 0, 0xA9FE, 0xA9FE},
    {0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE},
    {0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 1}
  ]

  # Addresses a listing opens, and only a listing.
  @private [
    {10, 0, 0, 5},
    {127, 0, 0, 1},
    {192, 168, 1, 10},
    {172, 16, 0, 1},
    {0, 0, 0, 0, 0, 0, 0, 1},
    {0xFD12, 0, 0, 0, 0, 0, 0, 1},
    {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0005},
    {0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0005}
  ]

  @public [{93, 184, 216, 34}, {0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}]

  describe "allowed_address?/2" do
    test "link-local and metadata addresses are never allowed, listed or not" do
      for address <- @never do
        assert HostPolicy.never?(address), inspect(address)
        refute HostPolicy.allowed_address?(address, true), inspect(address)
        refute HostPolicy.allowed_address?(address, false), inspect(address)
      end
    end

    test "private and loopback addresses only for a listed host" do
      for address <- @private do
        refute HostPolicy.never?(address), inspect(address)
        assert HostPolicy.allowed_address?(address, true), inspect(address)
        refute HostPolicy.allowed_address?(address, false), inspect(address)
      end
    end

    test "public addresses either way" do
      for address <- @public do
        assert HostPolicy.allowed_address?(address, true)
        assert HostPolicy.allowed_address?(address, false)
      end
    end
  end

  describe "check_host/3" do
    test "an unlisted loopback, .local, .internal or metadata name is refused" do
      assert {:error, "the host must not be a loopback host"} =
               HostPolicy.check_host("localhost", false, @sftp)

      assert {:error, "the host must not be a loopback host"} =
               HostPolicy.check_host("nas.localhost", false, @sftp)

      assert {:error, message} = HostPolicy.check_host("nas.local", false, @sftp)
      assert message =~ "BACKUP_SFTP_PRIVATE_HOSTS"
      assert {:error, _} = HostPolicy.check_host("foo.internal", false, @sftp)

      assert {:error, "the host must not be a metadata host"} =
               HostPolicy.check_host("metadata.google.internal", false, @sftp)
    end

    test "a listing opens a name and a private literal, never a metadata name or link-local" do
      assert :ok = HostPolicy.check_host("nas.local", true, @sftp)
      assert :ok = HostPolicy.check_host("127.0.0.1", true, @sftp)
      assert {:error, _} = HostPolicy.check_host("127.0.0.1", false, @sftp)
      assert {:error, _} = HostPolicy.check_host("metadata.google.internal", true, @sftp)

      assert {:error, message} = HostPolicy.check_host("169.254.169.254", true, @sftp)
      assert message =~ "link-local or metadata"
    end

    test "each adapter's refusal names its own variable and noun" do
      assert {:error, s3} = HostPolicy.check_host("10.0.0.5", false, @s3)
      assert {:error, sftp} = HostPolicy.check_host("10.0.0.5", false, @sftp)

      assert s3 ==
               "the endpoint resolves to a private or loopback address; " <>
                 "list its host in BACKUP_S3_PRIVATE_HOSTS to allow it"

      assert sftp ==
               "the host resolves to a private or loopback address; " <>
                 "list its host in BACKUP_SFTP_PRIVATE_HOSTS to allow it"
    end
  end

  describe "pin/3" do
    setup do
      safe_url = Application.get_env(:kiln_cms, KilnCMS.Webhooks.SafeUrl, [])

      answers = %{
        ~c"nas.example" => [{93, 184, 216, 34}],
        ~c"sneaky.example" => [{93, 184, 216, 34}, {10, 0, 0, 5}],
        ~c"meta.example" => [{169, 254, 169, 254}]
      }

      resolver = fn name ->
        case Map.fetch(answers, name) do
          {:ok, addresses} -> {:ok, {:hostent, name, [], :inet, 4, addresses}}
          :error -> {:error, :nxdomain}
        end
      end

      Application.put_env(
        :kiln_cms,
        KilnCMS.Webhooks.SafeUrl,
        Keyword.merge(safe_url, resolve_dns: true, resolver: resolver)
      )

      on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Webhooks.SafeUrl, safe_url) end)
    end

    test "a public name pins to its address; any private answer refuses an unlisted one" do
      assert HostPolicy.pin("nas.example", false, @sftp) == {:ok, {93, 184, 216, 34}}

      assert {:error, {:permanent, message}} = HostPolicy.pin("sneaky.example", false, @sftp)
      assert message =~ "BACKUP_SFTP_PRIVATE_HOSTS"
      assert {:ok, {93, 184, 216, 34}} = HostPolicy.pin("sneaky.example", true, @sftp)
    end

    test "a metadata answer is refused even listed; no answer may pass later" do
      assert {:error, {:permanent, message}} = HostPolicy.pin("meta.example", true, @sftp)
      assert message =~ "link-local or metadata"

      assert {:error, message} = HostPolicy.pin("nowhere.example", false, @sftp)
      assert is_binary(message)
    end
  end

  test "the private-hosts variable lists exact names only" do
    assert HostPolicy.parse_private_hosts(" NAS.lan, ,10.0.0.5,sftp://x.lan,a.lan:22,*.lan ") ==
             ["nas.lan", "10.0.0.5"]

    assert HostPolicy.parse_private_hosts(nil) == []
  end
end
