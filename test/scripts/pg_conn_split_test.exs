defmodule KilnCMS.Scripts.PgConnSplitTest do
  @moduledoc """
  `pg_conn_split` (with its helper `pg_conn_decode`), the shell copy of
  `KilnCMS.Backups.PgUrl.split/1` that
  `scripts/backup.sh`, `scripts/restore.sh` and `scripts/staging.sh` each
  carry (#2719, #2726).

  Each script has to run alone (hosts copy `backup.sh` by itself), so the
  function is copied rather than sourced. This holds the copies byte for byte
  identical, and runs the one in `backup.sh` against the table the Elixir
  module is tested with, under `bash` and, where it is installed (macOS), under
  `/bin/bash` 3.2. CI runs Linux, so the 3.2 case is only checked on a Mac.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.PgUrl

  @scripts ~w(backup restore staging) |> Enum.map(&Path.expand("../../scripts/#{&1}.sh", __DIR__))

  @bash3? File.exists?("/bin/bash") and
            match?(
              {"3\n", 0},
              System.cmd("/bin/bash", ["-c", "echo ${BASH_VERSINFO[0]}"], stderr_to_stdout: true)
            )

  unless System.find_executable("bash"), do: @moduletag(skip: "needs bash on PATH")

  test "the three scripts carry the same pg_conn_decode and pg_conn_split" do
    [first | rest] = Enum.map(@scripts, &function!/1)

    for {script, body} <- Enum.zip(tl(@scripts), rest) do
      assert body == first,
             "#{Path.basename(script)}'s pg_conn_decode/pg_conn_split differ from backup.sh's"
    end
  end

  test "pg_conn_split reads every case the way PgUrl.split/1 does" do
    assert_table!("bash")
  end

  unless @bash3?, do: @tag(skip: "needs /bin/bash 3.x (macOS)")

  test "and so it does under /bin/bash 3.2" do
    assert_table!("/bin/bash")
  end

  defp assert_table!(bash) do
    function = function!(hd(@scripts))

    for {label, input, _url, _password} <- KilnCMS.Test.PgUrlCases.cases() do
      {url, env} = PgUrl.split(input)
      expected = {url, List.keyfind(env, "PGPASSWORD", 0, {nil, nil}) |> elem(1)}

      assert shell_split(bash, function, input) == expected, label
    end
  end

  # Runs the extracted function on `input` (an argument, never interpolated
  # into the script) and reads back what it set.
  defp shell_split(bash, function, input) do
    script = """
    #{function}
    pg_conn_split "$1"
    printf '%s\\n%s\\n%s' "$PG_CONN_URL" "$PG_CONN_HAS_PASSWORD" "$PG_CONN_PASSWORD"
    """

    {out, 0} = System.cmd(bash, ["-c", script, "pg_conn_split_test", input])
    [url, has, password] = String.split(out, "\n", parts: 3)
    {url, if(has == "1", do: password)}
  end

  # Both functions, since pg_conn_split calls pg_conn_decode.
  defp function!(script) do
    source = File.read!(script)

    Enum.map_join(~w(pg_conn_decode pg_conn_split), fn name ->
      [body] = Regex.run(~r/^#{name}\(\) \{\n.*?^\}\n/ms, source)
      body
    end)
  end
end
