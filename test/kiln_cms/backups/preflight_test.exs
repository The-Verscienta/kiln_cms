defmodule KilnCMS.Backups.PreflightTest do
  @moduledoc """
  The free-space check before a backup writes a component (#2423), with the
  `:free_space` seam standing in for `df`. `async: false`: it changes the
  VM-wide `Application` env.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Backups.Preflight

  @moduletag :tmp_dir

  @mb 1_048_576

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Backups, original) end)
    %{original: original}
  end

  defp set_config(overrides) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Backups,
      Keyword.merge(Application.get_env(:kiln_cms, KilnCMS.Backups, []), overrides)
    )
  end

  # Free space as the seam reports it, and the path it was asked about.
  defp free(bytes) do
    parent = self()

    set_config(
      free_space: fn path ->
        send(parent, {:measured, path})
        bytes
      end
    )
  end

  describe "check/3" do
    test "refuses when free space is below the estimate plus 10% plus the margin", %{
      tmp_dir: tmp
    } do
      free({:ok, 1_099 * @mb})

      assert {:error, {:insufficient_space, info}} = Preflight.check(:db, tmp, 1_000 * @mb)
      assert info == %{component: :db, path: tmp, free: 1_099 * @mb, needed: 1_356 * @mb}
    end

    test "passes when free space covers what is needed, exactly or more", %{tmp_dir: tmp} do
      free({:ok, 1_356 * @mb})
      assert :ok = Preflight.check(:media, tmp, 1_000 * @mb)

      free({:ok, 50_000 * @mb})
      assert :ok = Preflight.check(:media, tmp, 1_000 * @mb)
    end

    test "warns and lets the backup go ahead when free space can't be read", %{tmp_dir: tmp} do
      free(:error)

      log = capture_log(fn -> assert :unknown = Preflight.check(:db, tmp, 1_000 * @mb) end)
      assert log =~ "Backup free-space check skipped: could not read the free space in #{tmp}"
    end

    test "measures the nearest directory that exists", %{tmp_dir: tmp} do
      free({:ok, 10_000 * @mb})

      assert :ok = Preflight.check(:media, Path.join([tmp, "media", "not-yet"]), 0)
      assert_received {:measured, ^tmp}

      File.mkdir_p!(Path.join(tmp, "media"))
      assert :ok = Preflight.check(:media, Path.join(tmp, "media"), 0)
      assert_received {:measured, measured}
      assert measured == Path.join(tmp, "media")
    end

    test "is off with free_space_check: false: nothing is measured", %{tmp_dir: tmp} do
      free({:ok, 0})
      set_config(free_space_check: false)

      assert :ok = Preflight.check(:db, tmp, 1_000 * @mb)
      refute_received {:measured, _}
      refute Preflight.enabled?()

      # Anything but false keeps it on.
      set_config(free_space_check: "no")
      assert Preflight.enabled?()
    end

    test "reads free space with df when no seam is set", %{tmp_dir: tmp, original: original} do
      Application.put_env(
        :kiln_cms,
        KilnCMS.Backups,
        original |> Keyword.delete(:free_space) |> Keyword.put(:free_space_margin_bytes, 0)
      )

      # A real reading of a real directory: anything but a refusal of nothing.
      assert :ok = Preflight.check(:db, tmp, 0)

      # More than any disk this runs on.
      assert {:error, {:insufficient_space, %{free: free}}} =
               Preflight.check(:db, tmp, 1_000_000_000 * @mb)

      assert free > 0
    end
  end

  describe "free_space/1 (#2984)" do
    test "reads the nearest directory that exists through the seam", %{tmp_dir: tmp} do
      free({:ok, 42 * @mb})

      assert {:ok, bytes} = Preflight.free_space(Path.join([tmp, "db", "not-yet"]))
      assert bytes == 42 * @mb
      assert_received {:measured, ^tmp}
    end

    test "is :error, without a log, when free space can't be read", %{tmp_dir: tmp} do
      free(:error)

      assert capture_log(fn -> assert :error = Preflight.free_space(tmp) end) == ""
    end

    test "reads df when no seam is set", %{tmp_dir: tmp, original: original} do
      Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.delete(original, :free_space))

      assert {:ok, bytes} = Preflight.free_space(tmp)
      assert bytes > 0
    end
  end

  describe "needed/1" do
    test "is the estimate plus 10% plus the configured margin" do
      assert Preflight.needed(0) == 256 * @mb
      assert Preflight.needed(1_000) == 1_100 + 256 * @mb

      set_config(free_space_margin_bytes: 0)
      assert Preflight.needed(0) == 0
      assert Preflight.needed(1_000) == 1_100

      # A margin that isn't a byte count keeps the default.
      set_config(free_space_margin_bytes: "lots")
      assert Preflight.margin_bytes() == 256 * @mb
    end
  end

  describe "dump_estimate/2" do
    test "is the size of the dump with the newest stamp before this run's", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "kiln-db-20261101-030000.dump"), String.duplicate("a", 300))
      File.write!(Path.join(tmp, "kiln-db-20261102-030000.dump"), String.duplicate("b", 200))
      # This run's own dump, a partial and a sidecar don't count.
      File.write!(Path.join(tmp, "kiln-db-20261103-030000.dump"), String.duplicate("c", 900))
      File.write!(Path.join(tmp, "kiln-db-20261103-030000.dump.1-1.partial"), "partial")
      File.write!(Path.join(tmp, "kiln-db-20261102-030000.sha256"), "sidecar")
      # An operator's copy without a stamp, and a name stamped after this run
      # (a clock that jumped back, a copy from another host), are not followed.
      File.write!(Path.join(tmp, "kiln-db-manual.dump"), String.duplicate("m", 5000))
      File.write!(Path.join(tmp, "kiln-db-20261201-000000.dump"), String.duplicate("f", 7000))
      File.write!(Path.join(tmp, "kiln-db-20261102-0300.dump"), String.duplicate("s", 8000))

      assert Preflight.dump_estimate(tmp, "20261103-030000") == 200

      # A newer symlink is passed over for the newest regular file.
      File.ln_s!("kiln-db-20261101-030000.dump", Path.join(tmp, "kiln-db-20261102-120000.dump"))
      assert Preflight.dump_estimate(tmp, "20261103-030000") == 200
    end

    test "is 0 with no earlier dump, or no db directory", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "kiln-db-manual.dump"), "m")
      assert Preflight.dump_estimate(tmp, "20261103-030000") == 0
      assert Preflight.dump_estimate(Path.join(tmp, "db"), "20261103-030000") == 0
    end
  end

  describe "lists_estimate/1" do
    test "is the largest list, missing ones counting 0", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "part01.list"), String.duplicate("x", 40))
      File.write!(Path.join(tmp, "part02.list"), String.duplicate("x", 70))
      paths = Enum.map(~w(part01.list part02.list part03.list), &Path.join(tmp, &1))

      assert Preflight.lists_estimate(paths) == 70
      assert Preflight.lists_estimate([]) == 0
    end
  end

  describe "parse_df/1" do
    test "reads GNU and BSD output" do
      gnu = """
      Filesystem     1024-blocks      Used Available Capacity Mounted on
      /dev/root         74244772  12300000  61943352      17% /
      """

      bsd = """
      Filesystem    1024-blocks      Used Available Capacity  Mounted on
      /dev/disk3s5    971350180 395375608 561974572    42%    /System/Volumes/Data
      """

      assert Preflight.parse_df(gnu) == {:ok, 61_943_352 * 1024}
      assert Preflight.parse_df(bsd) == {:ok, 561_974_572 * 1024}
    end

    test "a file system or mount point with spaces in its name still reads Available" do
      cifs = """
      Filesystem 1024-blocks Used Available Capacity Mounted on
      //host/Share Name 1000000 400000 600000 40% /mnt/share 50%
      """

      assert Preflight.parse_df(cifs) == {:ok, 600_000 * 1024}
    end

    test "16 EiB free (s3fs) is a number, and a negative Available (BSD reserve) is none" do
      s3fs = """
      Filesystem 1024-blocks Used Available Capacity Mounted on
      s3fs 18014398509481984 0 18014398509481984 0% /mnt/s3
      """

      assert Preflight.parse_df(s3fs) == {:ok, 18_014_398_509_481_984 * 1024}

      overdrawn = """
      Filesystem 1024-blocks Used Available Capacity Mounted on
      /dev/ada0p2 1000 1050 -50 105% /
      """

      assert Preflight.parse_df(overdrawn) == {:ok, 0}
    end

    test "anything else is :error" do
      assert :error = Preflight.parse_df("")
      assert :error = Preflight.parse_df("df: /nope: No such file or directory\n")
      assert :error = Preflight.parse_df("Filesystem Size\n/dev/root 74244772\n")
      assert :error = Preflight.parse_df("Filesystem\n/dev/root a b c 10% /\n")
    end
  end

  describe "describe/1" do
    test "names where, how much is free, how much is needed, and the ways out" do
      shortfall =
        {:insufficient_space,
         %{component: :db, path: "/var/backups/kiln/db", free: 1_288_490_188, needed: 300 * @mb}}

      assert Preflight.describe(shortfall) ==
               "Not enough free space for the database dump in /var/backups/kiln/db: " <>
                 "1.1 GB free, about 300 MB needed. Free up space there, or point BACKUP_DIR " <>
                 "at a larger disk (BACKUP_FREE_SPACE_CHECK=false skips this check)"

      assert Preflight.describe(
               {:insufficient_space, %{component: :media, path: "/b", free: 0, needed: 1980}}
             ) =~ "for the media archive in /b: 0 KB free, about 2 KB needed"

      assert Preflight.describe(
               {:insufficient_space, %{component: :lists, path: "/w", free: 5, needed: 9}}
             ) =~ "for the media file lists in /w"
    end

    test "free rounds down and needed rounds up, so the two never read alike" do
      # 1.0999… GB free, a byte more needed.
      free = 1_181_116_006

      assert Preflight.human(free, :down) == "1.0 GB"
      assert Preflight.human(free + 1, :up) == "1.2 GB"
      assert Preflight.human(free, :up) == "1.1 GB"
      assert Preflight.human(1_073_741_824 + 1, :up) == "1.1 GB"
      assert Preflight.human(1_073_741_824, :up) == "1.0 GB"
    end

    test "human/2 uses KB below 1 MB, whole MB below 1 GB, GB to a tenth above" do
      assert Preflight.human(0, :down) == "0 KB"
      assert Preflight.human(1, :up) == "1 KB"
      assert Preflight.human(1_048_575, :down) == "1023 KB"
      assert Preflight.human(1_048_576, :down) == "1 MB"
      assert Preflight.human(1_073_741_823, :down) == "1023 MB"
      assert Preflight.human(1_073_741_823, :up) == "1024 MB"
      assert Preflight.human(5 * 1_073_741_824 + 1_073_741_823, :down) == "5.9 GB"
      assert Preflight.human(5 * 1_073_741_824 + 1_073_741_823, :up) == "6.0 GB"
    end
  end
end
