defmodule KilnCMS.Backups.Destination.RcloneTest do
  @moduledoc """
  `KilnCMS.Backups.Destination.Rclone` (#2220), against a stub `rclone` that
  records its argv and `RCLONE_CONFIG_*` environment and keeps "uploaded"
  files in a directory.

  `async: false`: PATH and the `KilnCMS.Backups` application env are
  VM-global.
  """
  use ExUnit.Case, async: false

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups.Destination
  alias KilnCMS.Backups.Destination.Rclone

  @moduletag :tmp_dir

  @conn_remote ":s3,access_key_id=AKIAEXAMPLE1,secret_access_key=SUPERSECRETVAL:bucket"

  setup %{tmp_dir: tmp} do
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{rclone: fake_rclone!(tmp)}
  end

  defp remote!(remote) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.put(Application.get_env(:kiln_cms, KilnCMS.Backups, []), :rclone_remote, remote)
    )
  end

  defp env_config!(remote) do
    remote!(remote)
    {:ok, config} = Destination.resolve(Destination.env_destination())
    config
  end

  defp stored(settings), do: %Config{id: "1", key: "dest:1", kind: "rclone", settings: settings}

  # An rclone that logs its argv to `log` and its RCLONE_CONFIG_* environment
  # to `env`, one block per call. `copyto`/`cat`/`deletefile` act on `store`
  # by basename; `lsjson` prints `lsjson.<subdir>` or exits 3 (directory not
  # found); `listremotes` knows `r2` and `nas`. A `fail.<subcommand>` file
  # makes that subcommand exit 1. Otherwise, like an rclone whose config
  # loading has something to say, it prints a NOTICE to stderr unless it
  # gets `-q`.
  defp fake_rclone!(base) do
    bin = Path.join(base, "bin")
    store = Path.join(base, "store")
    File.mkdir_p!(bin)
    File.mkdir_p!(store)
    f = Map.new([:log, :env], &{&1, Path.join(base, "rclone.#{&1}")})

    File.write!(Path.join(bin, "rclone"), """
    #!/bin/sh
    echo "$*" >> "#{f.log}"
    env | grep '^RCLONE_CONFIG_' | sort >> "#{f.env}"
    echo -- >> "#{f.env}"
    [ -f "#{base}/fail.$1" ] && { echo "$1 refused" >&2; exit 1; }
    case " $* " in *" -q "*) ;; *) echo "NOTICE: Config file not found, using defaults" >&2 ;; esac
    case "$1" in
      copy) cp "$2" "#{store}/$(basename "$2")" ;;
      copyto) cp "$2" "#{store}/$(basename "$3")" ;;
      cat) cat "#{store}/$(basename "$2")" ;;
      deletefile) [ -f "#{store}/$(basename "$2")" ] || exit 4; rm "#{store}/$(basename "$2")" ;;
      lsjson)
        sub=$(basename "$3")
        [ -f "#{base}/lsjson.$sub" ] || { echo "directory not found" >&2; exit 3; }
        cat "#{base}/lsjson.$sub" ;;
      listremotes) printf 'r2:\\nnas:\\n' ;;
    esac
    exit 0
    """)

    File.chmod!(Path.join(bin, "rclone"), 0o755)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    Map.merge(f, %{exe: Path.join(bin, "rclone"), store: store, base: base})
  end

  defp lines(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp source!(tmp, name, body \\ "payload") do
    path = Path.join(tmp, name)
    File.write!(path, body)

    %{
      path: path,
      subdir: "db",
      name: name,
      bytes: byte_size(body),
      sha256: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    }
  end

  describe "put/3" do
    test "runs the off-site step's exact command and environment for the env remote",
         %{rclone: rclone, tmp_dir: tmp} do
      config = env_config!(@conn_remote)
      file = source!(tmp, "kiln-db-20260101-000000.dump")

      assert Destination.call(config, :put, [file, []]) == :ok

      assert lines(rclone.log) == ["copy #{file.path} kiln_offsite:bucket/db"]

      assert File.read!(rclone.env) ==
               """
               RCLONE_CONFIG_KILN_OFFSITE_ACCESS_KEY_ID=AKIAEXAMPLE1
               RCLONE_CONFIG_KILN_OFFSITE_SECRET_ACCESS_KEY=SUPERSECRETVAL
               RCLONE_CONFIG_KILN_OFFSITE_TYPE=s3
               --
               """
    end

    test "a named env remote is passed as it is, with no environment of its own",
         %{rclone: rclone, tmp_dir: tmp} do
      config = env_config!("r2:kiln-backups")
      file = %{source!(tmp, "kiln-media-20260101-000000.tar.gz") | subdir: "media"}

      assert Destination.call(config, :put, [file, []]) == :ok
      assert lines(rclone.log) == ["copy #{file.path} r2:kiln-backups/media"]
      assert File.read!(rclone.env) == "--\n"
    end

    test "a stored destination copies to <remote_name>:<path>/<subdir>",
         %{rclone: rclone, tmp_dir: tmp} do
      file = source!(tmp, "kiln-db-20260101-000000.dump")

      assert Rclone.put(stored(%{"remote_name" => "nas", "path" => "/kiln/site/"}), file, []) ==
               :ok

      assert lines(rclone.log) == ["copy #{file.path} nas:kiln/site/db"]
    end

    test "a failed copy is the command's error, scrubbed of the remote's secrets",
         %{rclone: rclone, tmp_dir: tmp} do
      File.write!(Path.join(rclone.base, "fail.copy"), "")
      config = env_config!(@conn_remote)
      file = source!(tmp, "kiln-db-20260101-000000.dump")

      assert {:error, {:exit_status, exe, 1, "copy refused\n"}} =
               Destination.call(config, :put, [file, []])

      assert exe == rclone.exe
    end

    test "without rclone it is :missing_rclone, and nothing runs", %{tmp_dir: tmp} do
      empty = Path.join(tmp, "empty_bin")
      File.mkdir_p!(empty)
      System.put_env("PATH", empty)

      config = env_config!("r2:kiln-backups")
      file = source!(tmp, "kiln-db-20260101-000000.dump")

      assert Destination.call(config, :put, [file, []]) == {:error, :missing_rclone}
      assert Destination.call(config, :list, []) == {:error, :missing_rclone}
      assert Destination.call(config, :test, []) == {:error, :missing_rclone}
    end
  end

  describe "list/1" do
    test "reads lsjson for db and media, and a missing directory is empty", %{rclone: rclone} do
      File.write!(Path.join(rclone.base, "lsjson.db"), """
      [
      {"Path":"kiln-db-20260101-000000.dump","Name":"kiln-db-20260101-000000.dump","Size":42,"ModTime":"2026-01-01T00:00:05.123456789Z","IsDir":false}
      ]
      """)

      config = stored(%{"remote_name" => "r2", "path" => "kiln"})

      assert {:ok, [entry]} = Rclone.list(config)
      assert entry.subdir == "db"
      assert entry.name == "kiln-db-20260101-000000.dump"
      assert entry.bytes == 42
      assert entry.mtime == ~U[2026-01-01 00:00:05Z]

      assert lines(rclone.log) == [
               "lsjson --files-only r2:kiln/db -q",
               "lsjson --files-only r2:kiln/media -q"
             ]
    end

    test "an lsjson failure other than a missing directory is an error", %{rclone: rclone} do
      File.write!(Path.join(rclone.base, "fail.lsjson"), "")

      assert {:error, {:exit_status, _exe, 1, _output}} =
               Rclone.list(stored(%{"remote_name" => "r2"}))
    end
  end

  describe "parse_listing/2" do
    test "keeps whole backup files and ignores every other name" do
      output = """
      2026/01/01 00:00:00 NOTICE: something rclone wanted to say
      [
      {"Name":"kiln-media-20260101-000000.part01.tar.gz","Size":10,"ModTime":"2026-01-01T00:00:00Z","IsDir":false},
      {"Name":"kiln-media-20260101-000000.sha256","Size":2,"ModTime":"2026-01-01T00:00:00Z","IsDir":false},
      {"Name":"kiln-media-20260101-000000.part02.tar.gz.partial","Size":3,"ModTime":"2026-01-01T00:00:00Z","IsDir":false},
      {"Name":"kiln-20260101-000000.keep","Size":0,"ModTime":"2026-01-01T00:00:00Z","IsDir":false},
      {"Name":"holiday.jpg","Size":9,"ModTime":"2026-01-01T00:00:00Z","IsDir":false},
      {"Name":"kiln-media-20260102-000000.tar.gz","IsDir":true},
      {"Name":"kiln-db-20260101-000000.dump","Size":"x","ModTime":"garbage","IsDir":false}
      ]
      """

      assert {:ok, entries} = Rclone.parse_listing("media", output)

      assert Enum.map(entries, & &1.name) == [
               "kiln-media-20260101-000000.part01.tar.gz",
               "kiln-media-20260101-000000.sha256",
               "kiln-db-20260101-000000.dump"
             ]

      assert %{bytes: 0, mtime: nil} = List.last(entries)
    end

    test "output that is not a listing is an error" do
      assert {:error, _reason} = Rclone.parse_listing("db", "Failed to lsjson: boom\n")
      assert {:error, _reason} = Rclone.parse_listing("db", "[not json")
    end
  end

  describe "delete/2 and get/3" do
    test "deletefile; a file already gone is success", %{rclone: rclone} do
      File.write!(Path.join(rclone.store, "kiln-db-20260101-000000.dump"), "x")
      config = stored(%{"remote_name" => "r2", "path" => "kiln"})
      ref = %{subdir: "db", name: "kiln-db-20260101-000000.dump"}

      assert Rclone.delete(config, ref) == :ok
      assert Rclone.delete(config, ref) == :ok

      assert lines(rclone.log) == [
               "deletefile r2:kiln/db/kiln-db-20260101-000000.dump -q",
               "deletefile r2:kiln/db/kiln-db-20260101-000000.dump -q"
             ]
    end

    test "refuses a name that is not a basename in db or media" do
      config = stored(%{"remote_name" => "r2"})

      assert {:error, _} = Rclone.delete(config, %{subdir: "db", name: "../escape"})
      assert {:error, _} = Rclone.delete(config, %{subdir: "etc", name: "passwd"})
      assert {:error, _} = Rclone.get(config, %{subdir: "db", name: ".."}, "/tmp/x")
    end

    test "copyto fetches a file", %{rclone: rclone, tmp_dir: tmp} do
      config = stored(%{"remote_name" => "r2", "path" => "kiln"})
      to = Path.join(tmp, "fetched.dump")

      assert Rclone.get(config, %{subdir: "db", name: "kiln-db-20260101-000000.dump"}, to) == :ok
      assert lines(rclone.log) == ["copyto r2:kiln/db/kiln-db-20260101-000000.dump #{to} -q"]
    end
  end

  describe "test/1" do
    test "writes a probe under .kiln-test, reads it back and removes it", %{rclone: rclone} do
      config = stored(%{"remote_name" => "r2", "path" => "kiln"})

      assert Rclone.test(config) == :ok

      assert [copyto, cat, deletefile] = lines(rclone.log)
      assert [_, local, target, "-q"] = String.split(copyto, " ")
      assert target =~ ~r"\Ar2:kiln/\.kiln-test/kiln-test-[0-9a-f]{16}\.txt\z"
      assert cat == "cat #{target} -q"
      assert deletefile == "deletefile #{target} -q"

      refute File.exists?(local)
      assert File.ls!(rclone.store) == []
      refute Destination.backup_file?(Path.basename(target))
    end

    test "cleans up after itself when the read back fails", %{rclone: rclone} do
      File.write!(Path.join(rclone.base, "fail.cat"), "")
      config = stored(%{"remote_name" => "r2", "path" => "kiln"})

      assert {:error, {:exit_status, _exe, 1, "cat refused\n"}} = Rclone.test(config)

      assert [copyto, _cat, deletefile] = lines(rclone.log)
      assert [_, local, target, "-q"] = String.split(copyto, " ")
      assert deletefile == "deletefile #{target} -q"
      refute File.exists?(local)
      assert File.ls!(rclone.store) == []
    end
  end

  describe "rclone's notices on stderr" do
    # `Command.output/3` merges stderr into what `cat`, `lsjson` and
    # `listremotes` print. Without `-q` the stub's NOTICE line would make the
    # probe's read back differ from what was written, so Test would fail.
    test "stay out of the probe, the listing and the remote list", %{rclone: rclone} do
      File.write!(Path.join(rclone.base, "lsjson.db"), """
      [{"Name":"kiln-db-20260101-000000.dump","Size":1,"ModTime":"2026-01-01T00:00:00Z","IsDir":false}]
      """)

      config = stored(%{"remote_name" => "r2", "path" => "kiln"})

      assert Rclone.test(config) == :ok
      assert {:ok, [%{name: "kiln-db-20260101-000000.dump"}]} = Rclone.list(config)
      assert Rclone.validate(config) == :ok

      assert Enum.all?(lines(rclone.log), &String.ends_with?(&1, " -q"))
    end

    test "are not silenced on the env destination's copy, whose argv is pinned",
         %{rclone: rclone, tmp_dir: tmp} do
      config = env_config!("r2:kiln-backups")
      file = source!(tmp, "kiln-db-20260101-000000.dump")

      assert Destination.call(config, :put, [file, []]) == :ok
      assert lines(rclone.log) == ["copy #{file.path} r2:kiln-backups/db"]
    end
  end

  describe "validate/1" do
    test "accepts a remote rclone.conf names" do
      assert Rclone.validate(stored(%{"remote_name" => "r2", "path" => "kiln/site"})) == :ok
      assert Rclone.validate(stored(%{"remote_name" => "nas"})) == :ok
    end

    test "refuses an unknown remote, an inline connection string and a local path" do
      assert {:error, message} = Rclone.validate(stored(%{"remote_name" => "b2"}))
      assert message =~ "no remote named b2"

      for name <- [":s3", "r2,secret_access_key=x", "r2:kiln", "/var/backups", "./x", "-r2", ""] do
        assert {:error, _} = Rclone.validate(stored(%{"remote_name" => name})), "for #{name}"
      end

      assert {:error, _} = Rclone.validate(stored(%{}))
    end

    test "refuses a path that climbs out, or carries control characters" do
      assert {:error, _} = Rclone.validate(stored(%{"remote_name" => "r2", "path" => "a/../b"}))
      assert {:error, _} = Rclone.validate(stored(%{"remote_name" => "r2", "path" => "a\nb"}))
    end

    test "refuses the env destination's shape, which only the environment sets" do
      assert {:error, message} = Rclone.validate(stored(%{"remote" => "r2:kiln"}))
      assert message =~ "BACKUP_RCLONE_REMOTE"
    end
  end

  describe "location/1 and Destination.overlap?/2" do
    test "foo:bar, foo:bar/ and foo:/bar are one location" do
      assert Rclone.location("foo:bar") == {:rclone, "foo", ["bar"]}
      assert Rclone.location("foo:bar/") == Rclone.location("foo:bar")
      assert Rclone.location("foo:/bar") == Rclone.location("foo:bar")
      assert Rclone.location("foo:bar//baz/./") == {:rclone, "foo", ["bar", "baz"]}

      assert Rclone.location(stored(%{"remote_name" => "foo", "path" => "/bar/"})) ==
               Rclone.location("foo:bar")
    end

    test "equal or nested locations overlap; siblings and other remotes don't" do
      overlap? = fn a, b -> Destination.overlap?(Rclone.location(a), Rclone.location(b)) end

      assert overlap?.("foo:bar", "foo:bar/")
      assert overlap?.("foo:bar", "foo:bar/baz")
      assert overlap?.("foo:bar/baz", "foo:/bar")
      assert overlap?.("foo:", "foo:bar")

      refute overlap?.("foo:bar", "foo:barn")
      refute overlap?.("foo:bar", "other:bar")
      refute overlap?.("foo:bar/a", "foo:bar/b")
    end

    test "a connection string is compared by the name rclone gets for it" do
      assert Rclone.location(@conn_remote) == {:rclone, "kiln_offsite", ["bucket"]}
      refute Destination.overlap?(Rclone.location(@conn_remote), Rclone.location("s3:bucket"))
    end

    test "a local-path remote is a local location, comparable with a Local destination" do
      assert Rclone.location("/var/backups/offsite") == {:local, ["var", "backups", "offsite"]}

      local = %Config{kind: "local", settings: %{"path" => "/var/backups/offsite/site"}}

      assert Destination.overlap?(
               Rclone.location("/var/backups/offsite/"),
               Destination.location(local)
             )

      refute Destination.overlap?(Destination.location(local), :unknown)
    end
  end
end
