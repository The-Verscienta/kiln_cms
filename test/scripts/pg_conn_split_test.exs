defmodule KilnCMS.Scripts.PgConnSplitTest do
  @moduledoc """
  `pg_conn_split` (with its helper `pg_conn_decode`), the shell copy of
  `KilnCMS.Backups.PgUrl.split/1` that
  `scripts/backup.sh`, `scripts/restore.sh` and `scripts/staging.sh` each
  carry (#2719, #2726, #2831, #2833).

  Each script has to run alone (hosts copy `backup.sh` by itself), so the
  function is copied rather than sourced. This holds the copies byte for byte
  identical, and runs the one in `backup.sh` against the table the Elixir
  module is tested with, under `bash` and under bash 3.2: macOS's `/bin/bash`,
  or the one CI's `backup_scripts_portability` job builds (`KILN_BASH32`).
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.PgUrl
  alias KilnCMS.Test.ShellTools

  # CI's `backup_scripts_portability` job runs this file under bash 3.2 and
  # under bsdtar (`--only shell_portability`).
  @moduletag :shell_portability

  @scripts ~w(backup restore staging) |> Enum.map(&Path.expand("../../scripts/#{&1}.sh", __DIR__))

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

  unless ShellTools.bash32(),
    do: @tag(skip: "needs bash 3.2 (/bin/bash on macOS, or KILN_BASH32)")

  test "and so it does under bash 3.2" do
    assert_table!(ShellTools.bash32())
  end

  defp assert_table!(bash) do
    function = function!(hd(@scripts))

    display_urls = KilnCMS.Test.PgUrlCases.display_urls()

    for {label, input, _url, _password} <- KilnCMS.Test.PgUrlCases.cases() do
      shell = shell_split(bash, function, input)

      case PgUrl.split(input) do
        {:ok, {url, env}} ->
          password = env |> List.keyfind("PGPASSWORD", 0, {nil, nil}) |> elem(1)
          assert {shell.url, shell.password} == {url, password}, label
          assert shell.error == "", label

          # What a script prints, or hands the app as its DATABASE_URL: the
          # password gone, the query as written (#2833).
          assert shell.display == Map.get(display_urls, input, url), label

        {:error, :refused_conninfo} ->
          assert shell.error =~ "is not a postgres:// URL", label
          assert {shell.url, shell.display, shell.password} == {"", "", nil}, label
      end
    end
  end

  # Runs the extracted function on `input` (an argument, never interpolated
  # into the script) and reads back what it set, one field per line; the
  # password, which may hold a newline, last.
  defp shell_split(bash, function, input) do
    script = """
    #{function}
    pg_conn_split "$1"
    printf '%s\\n%s\\n%s\\n%s\\n%s' "$PG_CONN_URL" "$PG_CONN_HAS_PASSWORD" \\
      "$PG_CONN_DISPLAY_URL" "$PG_CONN_ERROR" "$PG_CONN_PASSWORD"
    """

    {out, 0} = System.cmd(bash, ["-c", script, "pg_conn_split_test", input])
    [url, has, display, error, password] = String.split(out, "\n", parts: 5)
    %{url: url, display: display, error: error, password: if(has == "1", do: password)}
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
