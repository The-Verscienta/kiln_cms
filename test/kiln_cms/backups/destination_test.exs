defmodule KilnCMS.Backups.DestinationTest do
  @moduledoc """
  `KilnCMS.Backups.Destination` (#2220): the adapter registry, the env
  destination, and the boundary every adapter call goes through.

  `async: false`: the env-destination tests set `:rclone_remote` in the
  `KilnCMS.Backups` application env, which is VM-global. A `DataCase`:
  `active/0` reads the stored destinations too (none here).
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import KilnCMS.Test.BackupDestinations

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups.{Destination, Redact}
  alias KilnCMS.Backups.Destination.{Local, Rclone, S3}
  alias KilnCMS.Test.BackupDestinations.{Fake, ResumableFake}

  @secret "fake-secret-token-123"

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)
    :ok
  end

  defp remote!(remote) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups, []), :rclone_remote, remote)
    )
  end

  describe "registry/0" do
    test "lists Kiln's own adapters, then the plugins', then the test extras, in a fixed order" do
      registry = Destination.registry()

      assert [Rclone, Local, S3 | rest] = registry
      assert rest == [KilnDepFixture.BackupDestination, Fake, ResumableFake]
      assert Destination.registry() == registry
    end

    test "core_kinds/0 names Kiln's own kinds, the ones no plugin can take" do
      assert Destination.core_kinds() == ["rclone", "local", "s3"]
      assert Destination.adapter("s3") == {:ok, S3}
    end

    test "finds an adapter by kind, and an unknown kind is not installed" do
      assert Destination.adapter("rclone") == {:ok, Rclone}
      assert Destination.adapter("dep_fixture_dir") == {:ok, KilnDepFixture.BackupDestination}
      assert Destination.adapter("nope") == {:error, :not_installed}
      assert Destination.adapter(nil) == {:error, :not_installed}
    end

    test "an unknown kind is :not_installed for resolve/1 and call/4 alike" do
      entry = %{"key" => "dest:x", "id" => "x", "kind" => "nope", "source" => "db"}
      assert Destination.resolve(entry) == {:error, :not_installed}

      assert Destination.call(%Config{kind: "nope"}, :test, []) == {:error, :not_installed}
    end

    test "kind_of/1 refuses a module that is not an adapter" do
      assert Destination.kind_of(Local) == {:ok, "local"}
      assert Destination.kind_of(String) == :error
      assert Destination.kind_of(NoSuchModule) == :error
    end
  end

  describe "the env destination" do
    # The inputs of `rclone_remote_test.exs`: a named remote, an inline
    # backend, quoted values, and strings rclone itself would not parse.
    @remotes [
      "r2:kiln-backups",
      "r2:",
      ":s3:bucket",
      "/var/backups/offsite",
      ":s3,access_key_id=AKIAEXAMPLE1,secret_access_key=SUPERSECRETVAL:bucket/kiln",
      ~S{:s3,endpoint="https://acct.r2.example:443",secret-access-key='it''s,a:secret',env_auth:b},
      "r2,secret_access_key=SUPERSECRETVAL:kiln",
      "My_R2,token=abcdefgh:",
      "my-r2,secret_access_key=x:b",
      ":s3,secret_access_key='unterminated:b"
    ]

    test "records under the key a cron run's files have always had" do
      for remote <- @remotes do
        remote!(remote)
        entry = Destination.env_destination()

        assert entry["key"] == "rclone:" <> Redact.text(remote), "for #{remote}"
        assert entry["source"] == "env"
        assert entry["kind"] == "rclone"
        assert entry["id"] == nil
        assert Destination.active() == {:ok, [entry]}
      end
    end

    test "keeps no credential in the entry, literally" do
      remote!(":s3,access_key_id=AKIAEXAMPLE1,secret_access_key=SUPERSECRETVAL:bucket")
      entry = Destination.env_destination()

      assert entry["key"] == "rclone::s3,access_key_id=***,secret_access_key=***:bucket"
      refute inspect(entry) =~ "SUPERSECRETVAL"
      refute inspect(entry) =~ "AKIAEXAMPLE1"
    end

    test "resolves to the split remote, with the connection string's parameters as secrets" do
      remote = ":s3,access_key_id=AKIAEXAMPLE1,secret_access_key=SUPERSECRETVAL:bucket/kiln"
      remote!(remote)

      assert {:ok, %Config{} = config} = Destination.resolve(Destination.env_destination())
      assert config.key == Destination.env_destination()["key"]
      assert config.settings["remote"] == "kiln_offsite:bucket/kiln"

      assert config.secrets == %{
               "RCLONE_CONFIG_KILN_OFFSITE_TYPE" => "s3",
               "RCLONE_CONFIG_KILN_OFFSITE_ACCESS_KEY_ID" => "AKIAEXAMPLE1",
               "RCLONE_CONFIG_KILN_OFFSITE_SECRET_ACCESS_KEY" => "SUPERSECRETVAL"
             }

      refute inspect(config) =~ "SUPERSECRETVAL"
      refute Rclone.describe(config) =~ "SUPERSECRETVAL"
    end

    test "is gone once the remote is unset or changed" do
      remote!("r2:kiln-backups")
      entry = Destination.env_destination()

      remote!("r2:elsewhere")
      assert Destination.resolve(entry) == {:error, :removed}

      remote!(nil)
      assert Destination.env_destination() == nil
      assert Destination.active() == {:ok, []}
      assert Destination.resolve(entry) == {:error, :removed}
    end
  end

  describe "call/4" do
    test "passes a result through" do
      assert Destination.call(fake_config(), :test, []) == :ok
      assert_received {:fake_destination, :test, [], runner}
      refute runner == self()

      assert Destination.call(fake_config(), :list, []) == {:ok, []}
    end

    test "scrubs the destination's secrets from an error, literally and as key=value" do
      assert {:error, message} = Destination.call(fake_config(%{"mode" => "fail"}), :test, [])

      refute message =~ @secret
      assert message == "the store refused *** for token=*** today"
    end

    test "scrubs a key=value credential even when the value is too short to remove literally" do
      config = fake_config(%{"mode" => "fail"}, "ab1")

      assert {:error, message} = Destination.call(config, :test, [])
      assert message =~ "for token=*** today"
      refute message =~ "token=ab1"
    end

    test "a raising, exiting or throwing adapter is a redacted error, not a crash" do
      for mode <- ~w(raise exit throw) do
        assert {:error, message} =
                 Destination.call(fake_config(%{"mode" => mode}), :put, [%{}, []])

        assert message =~ "Fake.put/3"
        refute message =~ @secret, "for #{mode}"
        assert message =~ "***"
      end

      assert {:error, message} = Destination.call(fake_config(%{"mode" => "raise"}), :test, [])
      assert message =~ "raised: the store blew up holding ***"
    end

    test "an adapter that returns something else is an error that shows none of it" do
      assert {:error, message} =
               Destination.call(fake_config(%{"mode" => "bad_return"}), :test, [])

      assert message =~ "returned an unexpected value"
      refute message =~ @secret
    end

    test "a permanent failure keeps its tag, its message scrubbed (#2223)" do
      assert {:error, {:permanent, message}} =
               Destination.call(fake_config(%{"mode" => "permanent"}), :put, [%{}, []])

      assert message == "the bucket is gone for token=***"
      assert Destination.permanent?({:permanent, message})

      # A term in place of the message is inspected and scrubbed, the tag kept.
      assert {:error, {:permanent, inspected}} =
               Destination.call(fake_config(%{"mode" => "permanent_term"}), :put, [%{}, []])

      assert inspected =~ "no_such_bucket"
      refute inspected =~ @secret
      assert Destination.permanent?({:permanent, inspected})
    end

    test "a put may answer already present; any other {:ok, _} from it is an error" do
      assert {:ok, :already_present} =
               Destination.call(fake_config(%{"mode" => "present"}), :put, [%{}, []])

      assert {:error, message} =
               Destination.call(fake_config(%{"mode" => "ok_weird"}), :put, [%{}, []])

      assert message == "KilnCMS.Test.BackupDestinations.Fake.put/3 returned an unexpected value"

      # Other calls answer values as they always did.
      assert {:ok, :weird} =
               Destination.call(fake_config(%{"mode" => "ok_weird"}), :test, [])
    end

    test "the adapter's process carries the caller in $callers, so a Req.Test stub answers it" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.text(conn, "pong") end)

      assert {:ok, "pong"} =
               Destination.call(
                 fake_config(%{"mode" => "req", "req_stub" => __MODULE__}),
                 :test,
                 []
               )
    end

    test "a crashing process linked to the adapter is just that destination's error" do
      log =
        capture_log(fn ->
          assert {:error, message} =
                   Destination.call(fake_config(%{"mode" => "task_raise"}), :put, [%{}, []])

          assert message =~ "crashed: upload worker crashed"
          refute message =~ @secret
        end)

      assert Process.alive?(self())
      refute log =~ @secret
    end

    test "a hanging adapter times out, and its process is killed" do
      config = fake_config(%{"mode" => "sleep", "sleep_ms" => 60_000})

      assert {:error, reason} = Destination.call(config, :put, [%{}, []], timeout: 50)
      assert {:timeout, "KilnCMS.Test.BackupDestinations.Fake.put/3", 50} = reason
      assert Destination.timed_out?(reason)
      assert Destination.format_reason(reason) =~ "Fake.put/3 timed out after 50 ms"

      assert_received {:fake_destination, :put, _args, runner}
      ref = Process.monitor(runner)
      assert_receive {:DOWN, ^ref, :process, ^runner, _reason}
    end

    test "the default bound comes from config" do
      Application.put_env(:kiln_cms, Destination,
        extra_adapters: [Fake, ResumableFake],
        call_timeout: 1000
      )

      on_exit(fn ->
        Application.put_env(:kiln_cms, Destination, extra_adapters: [Fake, ResumableFake])
      end)

      config = fake_config(%{"mode" => "sleep", "sleep_ms" => 60_000})
      assert {:error, reason} = Destination.call(config, :test, [])
      assert Destination.format_reason(reason) =~ "timed out after 1 s"
    end

    test "a :deadline bounds the call by the time left, not by the default" do
      Application.put_env(:kiln_cms, Destination,
        extra_adapters: [Fake, ResumableFake],
        default_call_timeout: 50
      )

      on_exit(fn ->
        Application.put_env(:kiln_cms, Destination, extra_adapters: [Fake, ResumableFake])
      end)

      config = fake_config(%{"mode" => "sleep", "sleep_ms" => 300})
      deadline = System.monotonic_time(:millisecond) + :timer.minutes(10)

      assert {:error, {:timeout, _call, 50}} = Destination.call(config, :put, [%{}, []])
      assert Destination.call(config, :put, [%{}, []], deadline: deadline) == :ok
    end

    test "call_timeout/1: the time left, at least a second, capped by :call_timeout" do
      now = System.monotonic_time(:millisecond)

      assert Destination.call_timeout(timeout: 5) == 5
      assert Destination.call_timeout(deadline: now - 10_000) == 1000

      left = Destination.call_timeout(deadline: now + :timer.hours(2))
      assert left > :timer.minutes(119) and left <= :timer.hours(2)

      Application.put_env(:kiln_cms, Destination,
        extra_adapters: [Fake, ResumableFake],
        call_timeout: 300
      )

      on_exit(fn ->
        Application.put_env(:kiln_cms, Destination, extra_adapters: [Fake, ResumableFake])
      end)

      assert Destination.call_timeout(deadline: now + :timer.hours(2)) == 300
      assert Destination.call_timeout() == 300
    end

    test "a caller that is killed (a canceled backup) takes the adapter's process with it" do
      test = self()
      config = fake_config(%{"mode" => "sleep", "sleep_ms" => 60_000})

      caller = spawn(fn -> Destination.call(config, :put, [%{}, []]) end)

      assert_receive {:fake_destination, :put, _args, runner}
      ref = Process.monitor(runner)

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^runner, :killed}
      assert test == self()
    end
  end

  describe "format_reason/1" do
    test "says what a core adapter's reason means" do
      assert Destination.format_reason("plain") == "plain"

      assert Destination.format_reason({:exit_status, "rclone", 1, "nope\n"}) ==
               "rclone exited 1: nope\n"

      assert Destination.format_reason(:missing_rclone) =~ "rclone is not installed"
      assert Destination.format_reason(:not_installed) =~ "not installed"

      assert Destination.format_reason({:timeout, "Mod.put/3", 120_000}) ==
               "Mod.put/3 timed out after 2 min"
    end

    test "says the resumable-upload reasons (#2223)" do
      assert Destination.format_reason({:permanent, "no such bucket"}) == "no such bucket"
      assert Destination.format_reason(:deadline) =~ "resumes on the next attempt"
      assert Destination.format_reason(:superseded) =~ "took over the upload"
    end

    test "format_reason/2 says where a :deadline upload resumes (#3082)" do
      assert Destination.format_reason(:deadline, next_attempt?: true) ==
               "stopped before the step's time ran out; the upload resumes on the next attempt"

      assert Destination.format_reason(:deadline, next_attempt?: false) ==
               "stopped before the step's time ran out; it resumes when the backup is " <>
                 "resumed or runs again"

      assert Destination.format_reason(:deadline, []) == Destination.format_reason(:deadline)

      # Any other reason reads as format_reason/1 has it.
      assert Destination.format_reason(:superseded, next_attempt?: false) ==
               Destination.format_reason(:superseded)
    end

    test "permanent?/1 is the tagged reason with a message only" do
      assert Destination.permanent?({:permanent, "gone"})
      refute Destination.permanent?("permanent")
      refute Destination.permanent?({:permanent, :gone})
      refute Destination.permanent?(:deadline)
    end

    test "timed_out?/1 matches the tagged reason only, never text that reads like it" do
      assert Destination.timed_out?(:deadline)
      assert Destination.timed_out?({:timeout, "Mod.put/3", 50})
      refute Destination.timed_out?("Mod.put/3 timed out after 50 ms")
      refute Destination.timed_out?(:timeout)
    end
  end

  describe "target_key/2" do
    test "the env destination has none; a stored one's names its key and where it writes" do
      config = fake_config(%{"bucket" => "a"})
      assert Destination.target_key(%{"source" => "env", "key" => "rclone:x"}, config) == nil

      key = Destination.target_key(%{"source" => "db", "key" => "dest:1"}, config)
      assert key =~ ~r/\Adest:1\|[0-9a-f]{16}\z/

      moved = fake_config(%{"bucket" => "b"})
      refute Destination.target_key(%{"source" => "db", "key" => "dest:1"}, moved) == key
    end
  end

  describe "backup_file?/1" do
    test "is true for whole artifacts and sidecars only" do
      assert Destination.backup_file?("kiln-db-20260101-000000.dump")
      assert Destination.backup_file?("kiln-media-20260101-000000.part01.tar.gz")
      assert Destination.backup_file?("kiln-media-20260101-000000.sha256")

      refute Destination.backup_file?("kiln-db-20260101-000000.dump.partial")
      refute Destination.backup_file?("kiln-20260101-000000.keep")
      refute Destination.backup_file?("kiln-test-abcdef.txt")
      refute Destination.backup_file?("notes.txt")
    end
  end

  describe "S3 locations (#2221)" do
    defp s3(settings) do
      %Config{
        kind: "s3",
        settings:
          Map.merge(
            %{"endpoint" => "https://s3.test", "region" => "us-east-1", "bucket" => "kiln"},
            settings
          )
      }
    end

    test "normalize the host's case, the default port and the prefix's slashes" do
      a = Destination.location(s3(%{"endpoint" => "https://S3.Test", "prefix" => "/site/a/"}))
      b = Destination.location(s3(%{"endpoint" => "https://s3.test:443", "prefix" => "site/a"}))

      assert a == {:s3, "s3.test", 443, "kiln", ["site", "a"]}
      assert a == b
    end

    test "overlap on the same store and bucket when one prefix holds the other" do
      root = Destination.location(s3(%{}))
      site = Destination.location(s3(%{"prefix" => "site"}))
      other = Destination.location(s3(%{"prefix" => "sites"}))

      assert Destination.overlap?(root, site)
      assert Destination.overlap?(site, root)
      refute Destination.overlap?(site, other)

      refute Destination.overlap?(
               site,
               Destination.location(s3(%{"bucket" => "else", "prefix" => "site"}))
             )

      refute Destination.overlap?(
               site,
               Destination.location(
                 s3(%{"endpoint" => "https://s3.test:9000", "prefix" => "site"})
               )
             )
    end

    test "are never compared with an rclone remote" do
      refute Destination.overlap?(Destination.location(s3(%{})), {:rclone, "r2", ["kiln"]})
    end

    test "fix the endpoint, bucket and prefix once stored" do
      assert Destination.location_fields("s3") == ["endpoint", "bucket", "prefix"]
    end
  end
end
