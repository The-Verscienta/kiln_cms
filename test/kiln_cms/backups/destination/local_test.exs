defmodule KilnCMS.Backups.Destination.LocalTest do
  @moduledoc """
  `KilnCMS.Backups.Destination.Local` (#2220): where it may write, and that
  nothing it writes lands unverified.

  `async: false`: the roots and `BACKUP_DIR` live in the `KilnCMS.Backups`
  application env, which is VM-global.
  """
  use ExUnit.Case, async: false

  import Bitwise

  alias Kiln.BackupDestination.Config
  alias KilnCMS.Backups.Destination
  alias KilnCMS.Backups.Destination.Local

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)

    root = Path.join(tmp, "root")
    File.mkdir_p!(root)
    backups!(local_destination_roots: [root], dir: Path.join(tmp, "backups"), media_dir: nil)

    %{root: root}
  end

  defp backups!(opts) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Backups, []), opts)
    )
  end

  defp config(path),
    do: %Config{id: "1", key: "dest:1", kind: "local", settings: %{"path" => path}}

  defp source!(tmp, name, body \\ "the backup's bytes") do
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

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  describe "parse_roots/1" do
    test "reads comma-separated absolute directories, blanks ignored" do
      assert Local.parse_roots("/mnt/nas, /srv/backups/ ,,") ==
               {:ok, ["/mnt/nas", "/srv/backups"]}

      assert Local.parse_roots("  ") == {:ok, []}
    end

    test "refuses the whole list over one relative entry or a .." do
      assert Local.parse_roots("/mnt/nas,relative/dir") == :error
      assert Local.parse_roots("/mnt/nas/../etc") == :error
    end
  end

  describe "where it may write" do
    test "nowhere while BACKUP_LOCAL_DESTINATION_ROOTS is unset", %{root: root} do
      backups!(local_destination_roots: [])

      refute Local.available?()
      assert {:error, message} = Local.validate(config(root))
      assert message =~ "BACKUP_LOCAL_DESTINATION_ROOTS is not set"
    end

    test "under a root, or at it", %{root: root} do
      assert Local.available?()
      assert Local.validate(config(root)) == :ok
      assert Local.validate(config(Path.join(root, "site/new"))) == :ok
    end

    test "refuses a relative path, a .. and a control character", %{root: root} do
      assert {:error, "the path must be absolute"} = Local.validate(config("relative/dir"))

      assert {:error, "the path must not contain .."} =
               Local.validate(config(Path.join(root, "a/../../etc")))

      assert {:error, _} = Local.validate(config(Path.join(root, "a\nb")))
      assert {:error, "the path is missing"} = Local.validate(%Config{kind: "local"})
    end

    test "refuses a path outside every root", %{tmp_dir: tmp, root: root} do
      assert {:error, message} = Local.validate(config(Path.join(tmp, "elsewhere")))
      assert message =~ "is not under BACKUP_LOCAL_DESTINATION_ROOTS"

      # By whole segments: `root2` is not inside `root`.
      assert {:error, _} = Local.validate(config(root <> "2"))
    end

    test "refuses a symbolic link anywhere in the path", %{tmp_dir: tmp, root: root} do
      File.mkdir_p!(Path.join(tmp, "real"))
      File.ln_s!(Path.join(tmp, "real"), Path.join(root, "link"))

      assert {:error, message} = Local.validate(config(Path.join(root, "link/site")))
      assert message =~ "link is a symbolic link"
    end

    test "refuses a root that is itself reached through a symbolic link", %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join(tmp, "real_root"))
      File.ln_s!(Path.join(tmp, "real_root"), Path.join(tmp, "linked_root"))
      backups!(local_destination_roots: [Path.join(tmp, "linked_root")])

      assert {:error, message} = Local.validate(config(Path.join(tmp, "linked_root/site")))
      assert message =~ "linked_root is a symbolic link"
    end

    test "refuses a root that does not exist", %{tmp_dir: tmp} do
      backups!(local_destination_roots: [Path.join(tmp, "unmounted")])

      assert {:error, message} = Local.validate(config(Path.join(tmp, "unmounted/site")))
      assert message =~ "does not exist"
    end

    test "refuses BACKUP_DIR, anything inside it, and any ancestor of it", %{root: root} do
      backups!(dir: Path.join(root, "nas/backups"))

      for path <- ["nas/backups", "nas/backups/db", "nas", ""] do
        assert {:error, message} = Local.validate(config(Path.join(root, path))), "for #{path}"
        assert message =~ "overlaps BACKUP_DIR"
      end

      assert Local.validate(config(Path.join(root, "nas/other"))) == :ok
    end

    test "refuses MEDIA_DIR the same way", %{root: root} do
      backups!(media_dir: Path.join(root, "media"))

      assert {:error, message} = Local.validate(config(Path.join(root, "media/x")))
      assert message =~ "overlaps MEDIA_DIR"
    end

    test "refuses priv/static, recognized through the link the build puts in its path" do
      static = Application.app_dir(:kiln_cms, "priv/static")
      # `_build/…/priv` links to the project's `priv`; the real directory is
      # what a root would name.
      real_priv = Path.expand("priv", File.cwd!())
      backups!(local_destination_roots: [real_priv])

      assert File.dir?(static)
      assert {:error, message} = Local.validate(config(Path.join(real_priv, "static/backups")))
      assert message =~ "overlaps priv/static"
    end

    test "refuses the uploads directories", %{root: root} do
      uploads = Path.join(root, "uploads")
      previous = Application.get_env(:kiln_cms, KilnCMS.Storage.Local)

      Application.put_env(:kiln_cms, KilnCMS.Storage.Local, root: uploads)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, KilnCMS.Storage.Local, previous),
          else: Application.delete_env(:kiln_cms, KilnCMS.Storage.Local)
      end)

      assert {:error, message} = Local.validate(config(uploads))
      assert message =~ "overlaps the uploads directory"
    end
  end

  describe "put/3" do
    test "copies through a 0600 .partial, verified, into a 0700 directory",
         %{tmp_dir: tmp, root: root} do
      file = source!(tmp, "kiln-db-20260101-000000.dump")
      File.touch!(file.path, 1_700_000_000)
      dest = Path.join(root, "site")

      assert Destination.call(config(dest), :put, [file, []]) == :ok

      target = Path.join([dest, "db", file.name])
      assert File.read!(target) == File.read!(file.path)
      assert mode(target) == 0o600
      assert mode(dest) == 0o700
      assert mode(Path.join(dest, "db")) == 0o700
      assert File.stat!(target, time: :posix).mtime == 1_700_000_000
      refute File.exists?(target <> ".partial")
    end

    test "replaces a file already there", %{tmp_dir: tmp, root: root} do
      file = source!(tmp, "kiln-db-20260101-000000.dump", "new")
      File.mkdir_p!(Path.join(root, "db"))
      File.write!(Path.join([root, "db", file.name]), "old")

      assert Local.put(config(root), file, []) == :ok
      assert File.read!(Path.join([root, "db", file.name])) == "new"
    end

    test "a file already there with the same size and sha256 is not copied again (#2223)",
         %{tmp_dir: tmp, root: root} do
      file = source!(tmp, "kiln-db-20260101-000000.dump")
      assert Local.put(config(root), file, []) == :ok
      target = Path.join([root, "db", file.name])
      File.touch!(target, 1_600_000_000)

      assert Local.put(config(root), file, deadline: 0) == {:ok, :already_present}
      assert Destination.call(config(root), :put, [file, []]) == {:ok, :already_present}
      # Not rewritten.
      assert File.stat!(target, time: :posix).mtime == 1_600_000_000
    end

    test "a file there of the same size but other bytes is replaced", %{tmp_dir: tmp, root: root} do
      file = source!(tmp, "kiln-db-20260101-000000.dump", "same size, new")
      File.mkdir_p!(Path.join(root, "db"))
      File.write!(Path.join([root, "db", file.name]), "same size, old")

      assert Local.put(config(root), file, []) == :ok
      assert File.read!(Path.join([root, "db", file.name])) == "same size, new"
    end

    test "refuses a copy that does not match, and keeps nothing of it",
         %{tmp_dir: tmp, root: root} do
      file = source!(tmp, "kiln-db-20260101-000000.dump", "the whole file")
      # The source shrank after it verified: what is copied is not what was
      # hashed, as a truncated copy would not be.
      File.write!(file.path, "the whole")

      assert {:error, message} = Local.put(config(root), file, [])
      assert message =~ "did not match its checksum"

      assert File.ls!(Path.join(root, "db")) == []
    end

    test "checks the path again on every call, not only when saved", %{tmp_dir: tmp, root: root} do
      dest = Path.join(root, "site")
      file = source!(tmp, "kiln-db-20260101-000000.dump")
      assert Local.put(config(dest), file, []) == :ok

      File.rm_rf!(dest)
      File.mkdir_p!(Path.join(tmp, "elsewhere"))
      File.ln_s!(Path.join(tmp, "elsewhere"), dest)

      assert {:error, message} = Local.put(config(dest), file, [])
      assert message =~ "symbolic link"
      assert {:error, _} = Local.list(config(dest))
      assert {:error, _} = Local.delete(config(dest), %{subdir: "db", name: file.name})
      assert File.ls!(Path.join(tmp, "elsewhere")) == []

      backups!(local_destination_roots: [])
      assert {:error, _} = Local.list(config(root))
    end

    test "refuses a name that is not a basename in db or media", %{tmp_dir: tmp, root: root} do
      file = source!(tmp, "kiln-db-20260101-000000.dump")

      assert {:error, _} = Local.put(config(root), %{file | name: "../escape"}, [])
      assert {:error, _} = Local.put(config(root), %{file | subdir: "etc"}, [])
    end
  end

  describe "list/1 and delete/2" do
    setup %{root: root} do
      db = Path.join(root, "db")
      File.mkdir_p!(db)
      File.write!(Path.join(db, "kiln-db-20260101-000000.dump"), "dump")
      File.write!(Path.join(db, "kiln-db-20260101-000000.sha256"), "sum")
      File.write!(Path.join(db, "kiln-db-20260102-000000.dump.partial"), "half")
      File.write!(Path.join(db, "notes.txt"), "mine")
      File.mkdir_p!(Path.join(db, "kiln-db-20260103-000000.dump"))
      File.ln_s!(Path.join(db, "notes.txt"), Path.join(db, "kiln-db-20260104-000000.dump"))
      %{db: db}
    end

    test "lists regular backup files only", %{root: root} do
      assert {:ok, entries} = Local.list(config(root))

      assert Enum.map(entries, &{&1.subdir, &1.name, &1.bytes}) == [
               {"db", "kiln-db-20260101-000000.dump", 4},
               {"db", "kiln-db-20260101-000000.sha256", 3}
             ]

      assert %DateTime{} = hd(entries).mtime
    end

    test "deletes a regular file; a missing one is :ok; anything else is left alone",
         %{root: root, db: db} do
      dest = config(root)

      assert Local.delete(dest, %{subdir: "db", name: "kiln-db-20260101-000000.dump"}) == :ok
      refute File.exists?(Path.join(db, "kiln-db-20260101-000000.dump"))
      assert Local.delete(dest, %{subdir: "db", name: "kiln-db-20260101-000000.dump"}) == :ok
      assert Local.delete(dest, %{subdir: "media", name: "kiln-media-x.tar.gz"}) == :ok

      for name <- ["kiln-db-20260103-000000.dump", "kiln-db-20260104-000000.dump"] do
        assert {:error, message} = Local.delete(dest, %{subdir: "db", name: name})
        assert message =~ "not a regular file"
      end

      assert File.dir?(Path.join(db, "kiln-db-20260103-000000.dump"))
      assert File.read!(Path.join(db, "notes.txt")) == "mine"
    end

    test "a destination nothing was sent to yet lists nothing", %{root: root} do
      assert Local.list(config(Path.join(root, "fresh"))) == {:ok, []}
    end
  end

  describe "get/3" do
    test "copies a regular file out, and refuses a link", %{tmp_dir: tmp, root: root} do
      File.mkdir_p!(Path.join(root, "db"))
      File.write!(Path.join([root, "db", "kiln-db-20260101-000000.dump"]), "dump")
      File.ln_s!("/etc/hosts", Path.join([root, "db", "kiln-db-20260102-000000.dump"]))
      to = Path.join(tmp, "out.dump")

      assert Local.get(config(root), %{subdir: "db", name: "kiln-db-20260101-000000.dump"}, to) ==
               :ok

      assert File.read!(to) == "dump"

      assert {:error, _} =
               Local.get(config(root), %{subdir: "db", name: "kiln-db-20260102-000000.dump"}, to)
    end
  end

  describe "test/1" do
    test "writes and reads a probe, and leaves nothing behind", %{root: root} do
      dest = Path.join(root, "site")

      assert Local.test(config(dest)) == :ok
      assert File.ls!(dest) == []
    end

    test "fails on a path it may not use, writing nothing", %{tmp_dir: tmp} do
      assert {:error, _} = Local.test(config(Path.join(tmp, "elsewhere")))
      refute File.exists?(Path.join(tmp, "elsewhere"))
    end
  end

  test "location/1 is the expanded path's segments", %{root: root} do
    assert Local.location(config(root <> "/site/")) ==
             {:local, Path.split(root) |> tl() |> Kernel.++(["site"])}

    assert Destination.overlap?(
             Local.location(config(root)),
             Local.location(config(Path.join(root, "site")))
           )

    refute Destination.overlap?(
             Local.location(config(Path.join(root, "a"))),
             Local.location(config(Path.join(root, "b")))
           )
  end
end
