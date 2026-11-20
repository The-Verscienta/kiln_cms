defmodule KilnCMS.Backups.Destination.SftpTargetTest do
  @moduledoc """
  An SFTP destination's settings and credentials, checked offline (#2222):
  what a host, port, user and path may be, where it writes for the overlap
  and retention rules, and which keys are accepted, all without contacting
  anything.
  """
  use ExUnit.Case, async: true

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups.{Destination, Retention}
  alias KilnCMS.Backups.Destination.Sftp
  alias KilnCMS.Backups.Destination.Sftp.{Credentials, Errors, HostKey, Target, Upload}
  alias KilnCMS.Test.SftpServer

  @settings %{"host" => "nas.example.com", "username" => "kiln", "path" => "/backups/kiln"}

  defp parse(overrides, listed \\ []), do: Target.parse(Map.merge(@settings, overrides), listed)

  describe "settings" do
    test "a host, user and absolute path; port 22 when blank" do
      assert {:ok, %Target{host: "nas.example.com", port: 22, username: "kiln"} = target} =
               parse(%{})

      assert target.segments == ["backups", "kiln"]
      assert {:ok, %Target{port: 2222}} = parse(%{"port" => 2222})
      assert {:ok, %Target{host: "nas.example.com"}} = parse(%{"host" => "NAS.Example.com."})
    end

    test "the host is a name or a literal, nothing more" do
      for host <- ["sftp://nas", "nas:22", "user@nas", "nas/x", "", "a b"] do
        assert {:error, _} = parse(%{"host" => host}), inspect(host)
      end

      assert {:error, _} = parse(%{"port" => 0})
      assert {:error, _} = parse(%{"port" => 70_000})
      assert {:error, _} = parse(%{"port" => "22"})
    end

    test "the path is absolute, with no climbing out and nothing but safe characters" do
      for path <- ["backups", "~/x", "/a/../../b", "/../x", "/a/./b", "/a b", "/a\0b", "../x"] do
        assert {:error, _} = parse(%{"path" => path}), inspect(path)
      end

      assert {:error, "the path must be absolute, e.g. /backups/kiln"} =
               parse(%{"path" => "backups/kiln"})
    end

    test "the username has no control characters and no @" do
      for name <- ["", "a\nb", "a@b", "a\0"] do
        assert {:error, _} = parse(%{"username" => name}), inspect(name)
      end
    end

    test "private, loopback and local names need BACKUP_SFTP_PRIVATE_HOSTS; metadata never" do
      assert {:error, message} = parse(%{"host" => "127.0.0.1"})
      assert message =~ "BACKUP_SFTP_PRIVATE_HOSTS"
      assert {:ok, _} = parse(%{"host" => "127.0.0.1"}, ["127.0.0.1"])

      assert {:error, _} = parse(%{"host" => "nas.local"})
      assert {:ok, _} = parse(%{"host" => "nas.local"}, ["nas.local"])
      assert {:error, _} = parse(%{"host" => "foo.internal"})

      assert {:error, _} =
               parse(%{"host" => "metadata.google.internal"}, ["metadata.google.internal"])

      assert {:error, message} = parse(%{"host" => "169.254.169.254"}, ["169.254.169.254"])
      assert message =~ "link-local or metadata"
    end

    test "validate/1 wants a usable credential" do
      config = %Config{kind: "sftp", settings: @settings}

      assert {:error, "enter a password, a private key, or both"} = Sftp.validate(config)
      assert :ok = Sftp.validate(%{config | secrets: %{"password" => "x"}})

      assert :ok =
               Sftp.validate(%{
                 config
                 | secrets: %{"private_key" => SftpServer.pem(SftpServer.ed25519())}
               })
    end
  end

  describe "private keys" do
    test "Ed25519, ECDSA and RSA (2048+) in PEM; a CRLF paste reads" do
      ed = SftpServer.pem(SftpServer.ed25519())
      assert {:ok, _key, [:"ssh-ed25519"]} = Credentials.private_key(ed)

      assert {:ok, _key, [:"ssh-ed25519"]} =
               Credentials.private_key(String.replace(ed, "\n", "\r\n"))

      ec = :public_key.generate_key({:namedCurve, :secp384r1})
      ec_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec)])
      assert {:ok, _key, [:"ecdsa-sha2-nistp384"]} = Credentials.private_key(ec_pem)

      rsa = :public_key.generate_key({:rsa, 2048, 65_537})
      rsa_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa)])
      assert {:ok, _key, [:"rsa-sha2-512", :"rsa-sha2-256"]} = Credentials.private_key(rsa_pem)
    end

    test "short RSA, passphrases and garbage are refused with fixed sentences" do
      rsa = :public_key.generate_key({:rsa, 1024, 65_537})
      rsa_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa)])
      assert {:error, message} = Credentials.private_key(rsa_pem)
      assert message =~ "2048"

      assert {:error, message} =
               Credentials.private_key(
                 "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAAAA\n-----END RSA PRIVATE KEY-----"
               )

      assert message =~ "ssh-keygen -p"

      # An OpenSSH key whose cipher isn't "none" (as `ssh-keygen -N secret`
      # writes): refused before OTP is asked to open it.
      encrypted =
        "-----BEGIN OPENSSH PRIVATE KEY-----\n" <>
          Base.encode64(<<"openssh-key-v1", 0, 10::32, "aes256-ctr", 6::32, "bcrypt">>) <>
          "\n-----END OPENSSH PRIVATE KEY-----"

      assert {:error, message} = Credentials.private_key(encrypted)
      assert message =~ "passphrase"

      secret_bytes =
        "-----BEGIN OPENSSH PRIVATE KEY-----\nc2VjcmV0LWJ5dGVz\n-----END OPENSSH PRIVATE KEY-----"

      assert {:error, message} = Credentials.private_key(secret_bytes)
      refute message =~ "c2VjcmV0"
    end

    test "inspecting credentials shows neither secret" do
      pem = SftpServer.pem(SftpServer.ed25519())

      {:ok, credentials} =
        Credentials.from_secrets("kiln", %{"password" => "hunter2-pass", "private_key" => pem})

      text = inspect(credentials)
      refute text =~ "hunter2-pass"
      refute text =~ "PRIVATE"
      assert text =~ "kiln"
    end
  end

  describe "host keys" do
    test "a pasted fingerprint is normalized; anything else is not one" do
      fp = "SHA256:" <> String.duplicate("a", 43)

      assert {:ok, ^fp} =
               HostKey.normalize_fingerprint("  sha256:" <> String.duplicate("a", 43) <> "=")

      assert {:ok, ^fp} = HostKey.normalize_fingerprint(String.duplicate("a", 43))
      assert :error = HostKey.normalize_fingerprint("MD5:aa:bb")
      assert :error = HostKey.normalize_fingerprint("SHA256:short")
    end

    test "a refused key is an error, never false (false would prompt on the group leader)" do
      key = SftpServer.ed25519()
      public = SftpServer.public(key)
      trusted = HostKey.fingerprint(public)
      tag = make_ref()

      options = fn mode -> [key_cb_private: [mode: mode, reply_to: self(), tag: tag]] end

      assert HostKey.is_host_key(
               public,
               ~c"h",
               22,
               :"ssh-ed25519",
               options.({:verify, "ssh-ed25519", trusted})
             )

      for mode <- [
            {:verify, "ssh-ed25519", "SHA256:" <> String.duplicate("B", 43)},
            {:verify, "ssh-rsa", trusted},
            {:scan, nil},
            nil
          ] do
        assert {:error, _} =
                 HostKey.is_host_key(public, ~c"h", 22, :"ssh-ed25519", options.(mode))
      end

      assert_received {^tag, :offered, "ssh-ed25519", ^trusted}
    end

    test "only the trusted type's algorithms are offered; RSA with SHA-2 only" do
      assert HostKey.algorithms("ssh-rsa") == [:"rsa-sha2-512", :"rsa-sha2-256"]
      assert HostKey.algorithms("ssh-ed25519") == [:"ssh-ed25519"]
    end
  end

  describe "where it writes" do
    test "location is host, port, user and path; the host key is no part of it" do
      config = %Config{kind: "sftp", settings: Map.put(@settings, "host", "NAS.example.com.")}

      assert Destination.location(config) ==
               {:sftp, "nas.example.com", 22, "kiln", ["backups", "kiln"]}

      keyed = %{
        config
        | settings: Map.merge(config.settings, %{Sftp.fingerprint_key() => "SHA256:x"})
      }

      assert Destination.location(keyed) == Destination.location(config)
      assert Destination.location_fields("sftp") == ["host", "port", "username", "path"]
      assert Sftp.describe(config) == "sftp://kiln@nas.example.com:22/backups/kiln"
    end

    test "overlap: same server, port and user, one path in the other" do
      a = {:sftp, "nas", 22, "kiln", ["backups"]}

      assert Destination.overlap?(a, {:sftp, "nas", 22, "kiln", ["backups", "kiln"]})
      refute Destination.overlap?(a, {:sftp, "nas", 22, "other", ["backups"]})
      refute Destination.overlap?(a, {:sftp, "nas", 22, "kiln", ["elsewhere"]})

      # Another name, port or login may be the same disk.
      assert Destination.possible_overlap?(a, {:sftp, "10.0.0.5", 2222, "root", ["backups", "x"]})
      refute Destination.possible_overlap?(a, {:sftp, "nas", 22, "kiln", ["other"]})
      refute Destination.possible_overlap?(a, {:s3, "nas", 22, "backups", []})
    end

    test "retention: SFTP can't be compared with BACKUP_RCLONE_REMOTE either way" do
      row = %{id: "a", kind: "sftp", settings: @settings}
      config = %Config{id: "a", key: "dest:a", kind: "sftp", settings: @settings}
      env = {:rclone, "r2", ["kiln"]}

      assert Retention.prune_blocker(config, [row], env) == :env_overlap_unknown
      assert Retention.prune_blocker(:env, [row], env) == :destination_sftp
      assert Retention.prune_blocker(config, [row], nil) == nil
      assert Retention.describe(:destination_sftp) =~ "SFTP"
    end

    test "retention: another SFTP path inside or around this one blocks both" do
      other = %{
        id: "b",
        kind: "sftp",
        settings: %{@settings | "host" => "10.0.0.5", "path" => "/backups"}
      }

      row = %{id: "a", kind: "sftp", settings: @settings}
      config = %Config{id: "a", key: "dest:a", kind: "sftp", settings: @settings}

      assert Retention.prune_blocker(config, [row, other], nil) ==
               :destination_overlap_possible_sftp

      assert Retention.describe(:destination_overlap_possible_sftp) =~ "SFTP"
    end
  end

  describe "temporary names" do
    test "a step's partials are swept; a resumable upload's token partials never are" do
      name = "kiln-db-20260101-000000.dump"

      assert Upload.step_partial?(name <> ".partial")
      assert Upload.step_partial?(name <> ".12-1.partial")
      refute Upload.step_partial?(name <> ".0123456789abcdef.partial")
      refute Upload.step_partial?(name <> ".1234567890123456.partial")
      refute Upload.step_partial?("notes.partial")
      refute Upload.step_partial?(name)
    end

    test "only a 16-hex token is one" do
      assert Upload.token?("0123456789abcdef")
      refute Upload.token?("../../x")
      refute Upload.token?("0123456789ABCDEF")
      refute Upload.token?(nil)
    end
  end

  test "after the host key checked out, only a refused login is permanent" do
    fp = "SHA256:" <> String.duplicate("a", 43)
    offered = {"ssh-ed25519", fp}
    mode = {:verify, "ssh-ed25519", fp}

    assert Errors.connect_reason(
             ~c"Unable to connect using the available authentication methods",
             offered,
             mode
           ) == {:permanent, "the server refused the username and credentials"}

    for reason <- [:timeout, :closed, ~c"Connection closed", {:exit, :boom}] do
      assert is_binary(Errors.connect_reason(reason, offered, mode)), inspect(reason)
    end

    assert {:host_key_mismatch, "ssh-ed25519", _} =
             Errors.connect_reason(
               :closed,
               {"ssh-ed25519", "SHA256:" <> String.duplicate("b", 43)},
               mode
             )
  end

  test "server text is never repeated in an error" do
    assert Errors.connect_reason(~c"Banner: evil text authentication", nil, {:verify, "t", "f"}) ==
             {:permanent, "the server refused the username and credentials"}

    assert Errors.op(:write, "writing x", {:weird, "server says hi"}) ==
             "writing x: the server reported an error"
  end
end
