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
    test "is the size of the newest earlier dump", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "kiln-db-20261101-030000.dump"), String.duplicate("a", 300))
      File.write!(Path.join(tmp, "kiln-db-20261102-030000.dump"), String.duplicate("b", 200))
      # This run's own dump, a partial and a sidecar don't count.
      File.write!(Path.join(tmp, "kiln-db-20261103-030000.dump"), String.duplicate("c", 900))
      File.write!(Path.join(tmp, "kiln-db-20261103-030000.dump.1-1.partial"), "partial")
      File.write!(Path.join(tmp, "kiln-db-20261102-030000.sha256"), "sidecar")

      assert Preflight.dump_estimate(tmp, "20261103-030000") == 200

      # A newer symlink is passed over for the newest regular file.
      File.ln_s!("kiln-db-20261101-030000.dump", Path.join(tmp, "kiln-db-20261102-120000.dump"))
      assert Preflight.dump_estimate(tmp, "20261103-030000") == 200
    end

    test "is 0 with no earlier dump, or no db directory", %{tmp_dir: tmp} do
      assert Preflight.dump_estimate(tmp, "20261103-030000") == 0
      assert Preflight.dump_estimate(Path.join(tmp, "db"), "20261103-030000") == 0
    end
  end

  describe "describe/1" do
    test "names where, how much is free, how much is needed, and the way out" do
      shortfall =
        {:insufficient_space,
         %{component: :db, path: "/var/backups/kiln/db", free: 1_288_490_188, needed: 300 * @mb}}

      assert Preflight.describe(shortfall) ==
               "Not enough free space for the database dump in /var/backups/kiln/db: " <>
                 "1.1 GB free, about 300 MB needed. Free up space there, or point BACKUP_DIR " <>
                 "at a larger disk"

      assert Preflight.describe(
               {:insufficient_space, %{component: :media, path: "/b", free: 0, needed: 0}}
             ) =~ "for the media archive in /b"
    end

    test "human/1 rounds down to whole MB, or to a tenth of a GB" do
      assert Preflight.human(0) == "0 MB"
      assert Preflight.human(1_073_741_823) == "1023 MB"
      assert Preflight.human(1_073_741_824) == "1.0 GB"
      assert Preflight.human(5 * 1_073_741_824 + 1_073_741_823) == "5.9 GB"
    end
  end
end
