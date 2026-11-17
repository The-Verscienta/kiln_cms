defmodule KilnCMS.Test.Libpq do
  @moduledoc """
  libpq's own connection-string parser (`PQconninfoParse`), for checking what
  `KilnCMS.Backups.PgUrl` and the scripts' `pg_conn_split` hand
  `pg_dump`/`psql` (#2831, #2833): the URL libpq reads, not the one a test
  author believes it reads.

  Runs `test/support/libpq_conninfo.py` with `python3 -I` (isolated: no
  user site-packages, no script directory on the path) through `ctypes`, so
  no C toolchain is needed. The `:libpq` tag is excluded in `test_helper.exs`
  where python3 or libpq is missing, except under `CI`, where a missing one
  fails the tests instead of skipping them.
  """

  @script Path.expand("libpq_conninfo.py", __DIR__)

  @typedoc "`{:ok, %{keyword => value}}` or libpq's `{:error, message}`."
  @type parsed :: {:ok, %{String.t() => binary()}} | {:error, String.t()}

  @doc "Whether python3 and libpq are both here."
  @spec available?() :: boolean()
  def available? do
    System.find_executable("python3") != nil and match?({:ok, [_]}, run([""]))
  rescue
    _ -> false
  end

  @doc "`PQconninfoParse` of each string, as pg_dump would see it."
  @spec parse!([String.t()]) :: [parsed()]
  def parse!(strings) do
    case run(strings) do
      {:ok, results} -> results
      {:error, message} -> raise "libpq_conninfo.py failed: #{message}"
    end
  end

  defp run(strings) do
    input = Jason.encode!(Enum.map(strings, &Base.encode16(&1, case: :lower)))
    stdin = Path.join(System.tmp_dir!(), "kiln_libpq_#{System.unique_integer([:positive])}.json")
    File.write!(stdin, input)

    try do
      case System.cmd(
             "sh",
             ["-c", ~s(exec python3 -I "$1" "$2" < "$3"), "sh", @script, libdir(), stdin],
             stderr_to_stdout: true
           ) do
        {out, 0} -> {:ok, out |> Jason.decode!() |> Enum.map(&result/1)}
        {out, _status} -> {:error, out}
      end
    after
      File.rm(stdin)
    end
  end

  defp result(%{"ok" => options}),
    do: {:ok, Map.new(options, fn {key, hex} -> {key, Base.decode16!(hex, case: :lower)} end)}

  defp result(%{"error" => message}), do: {:error, message}

  defp libdir do
    with exe when is_binary(exe) <- System.find_executable("pg_config"),
         {dir, 0} <- System.cmd(exe, ["--libdir"], stderr_to_stdout: true) do
      String.trim(dir)
    else
      _ -> ""
    end
  end
end
