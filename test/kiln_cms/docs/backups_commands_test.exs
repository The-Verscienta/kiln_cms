defmodule KilnCMS.Docs.BackupsCommandsTest do
  @moduledoc """
  The History import command in `docs/backups.md` ("Cron's backups appear in
  History") works as written (#2488).

  It used to read `bin/kiln eval "KilnCMS.Backups.Importer.run()"`: the wrong
  binary, and `eval` starts no Repo, so it imported nothing. No release smoke
  test runs `rpc`, so this test runs the documented expression itself, against
  a backup directory holding one settled cron backup, and checks that what it
  prints has the shape the page shows.
  """
  # `async: false`: it points `:kiln_cms, KilnCMS.Backups, :dir` at a temp
  # directory (`Application.put_env` is VM-global).
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  @moduletag :capture_log

  @doc_path Path.expand("../../../docs/backups.md", __DIR__)
  @external_resource @doc_path
  @heading "### Cron's backups appear in History"

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln_doc_imp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "db"))

    original = Application.get_env(:kiln_cms, KilnCMS.Backups, [])
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.merge(original, dir: dir))

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:kiln_cms, KilnCMS.Backups, original)
    end)

    %{dir: dir}
  end

  # The one fenced block of the section, as `{command, sample_output}`.
  defp documented_command do
    section =
      @doc_path
      |> File.read!()
      |> String.split(@heading, parts: 2)
      |> List.last()
      # The next `##`/`###` heading; the block's own `# …` comment is not one.
      |> String.split(~r/^\#{2,} /m, parts: 2)
      |> hd()

    assert [[block]] = Regex.scan(~r/^```bash\n(.*?)^```/ms, section, capture: :all_but_first)
    assert [command, "# " <> sample] = String.split(block, "\n", trim: true)
    {command, sample}
  end

  test "the section shows rpc against the running node, never eval" do
    {command, _sample} = documented_command()

    assert String.starts_with?(command, "bin/kiln_cms rpc '")
    refute File.read!(@doc_path) =~ ~r/bin\/kiln(_cms)? eval[^\n]*Importer/
  end

  test "the documented expression imports a settled cron backup and prints the sample's shape",
       %{dir: dir} do
    {command, sample} = documented_command()

    # Single-quoted for the shell: the expression itself must hold no `'`.
    assert [_, expression] = Regex.run(~r/\Abin\/kiln_cms rpc '([^']*)'\z/, command)

    # A cron `backup.sh db` dump, past the 10-minute settle window.
    path = Path.join([dir, "db", "kiln-db-20260801-031700.dump"])
    File.write!(path, String.duplicate("x", 100))
    File.touch!(path, System.os_time(:second) - 3600)

    printed = capture_io(fn -> Code.eval_string(expression) end)

    {expected, _} = Code.eval_string(sample)
    {actual, _} = Code.eval_string(String.trim(printed))

    assert Map.keys(actual) == Map.keys(expected)
    assert actual == %{failed: 0, imported: 1, pending: 0, skipped: 0}
    assert String.trim(printed) == inspect(actual)
  end

  test "a failed import makes the documented expression raise, so rpc exits non-zero" do
    {command, _sample} = documented_command()
    [_, expression] = Regex.run(~r/\Abin\/kiln_cms rpc '([^']*)'\z/, command)

    # A directory that cannot be listed is `{:error, _}` from the importer.
    original = Application.get_env(:kiln_cms, KilnCMS.Backups)
    file = Path.join(System.tmp_dir!(), "kiln_doc_notdir_#{System.unique_integer([:positive])}")
    File.write!(file, "")
    on_exit(fn -> File.rm(file) end)
    Application.put_env(:kiln_cms, KilnCMS.Backups, Keyword.put(original, :dir, file))

    assert_raise MatchError, fn -> capture_io(fn -> Code.eval_string(expression) end) end
  end
end
