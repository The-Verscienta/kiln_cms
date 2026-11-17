defmodule KilnCMS.Backups.PgUrlLibpqTest do
  @moduledoc """
  The shared connection-string table (`KilnCMS.Test.PgUrlCases`) against
  libpq's own parser (`PQconninfoParse`, through `KilnCMS.Test.Libpq`), so the
  claims `KilnCMS.Backups.PgUrl` and the scripts' `pg_conn_split` make about
  libpq are libpq's, not the test author's (#2831, #2833):

    * what is handed to libpq reads exactly as the input would, less the
      password, which libpq would have read as the one the case expects;
    * where the input carries Ecto's own parameters, which libpq refuses, the
      output reads as the translation is meant to (`libpq_equivalents/0`);
    * a refused string really would have put its secret where libpq reads it.

  Excluded (`:libpq`) where python3 or libpq is missing; never under CI.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.PgUrl
  alias KilnCMS.Test.{Libpq, PgUrlCases}

  @moduletag :libpq

  # For each refused case: the option libpq reads the secret into, and its
  # value.
  @refused %{
    "mysql://u:pw@h/db" => {"dbname", "mysql://u:pw@h/db"},
    " postgres://u:pw@h/db" => {"dbname", " postgres://u:pw@h/db"},
    "host=db password=x dbname=kiln" => {"password", "x"},
    "host=db password='a b\\'c' dbname=kiln" => {"password", "a b'c"},
    "host=db sslpassword=x dbname=kiln" => {"sslpassword", "x"},
    "dbname='postgres://u:s@h/db'" => {"dbname", "postgres://u:s@h/db"},
    "password=x" => {"password", "x"},
    "host=db password = x" => {"password", "x"},
    "host='x'password=y dbname=kiln" => {"password", "y"}
  }

  test "the harness is libpq: it refuses an Ecto option by name" do
    assert [{:error, message}, {:ok, %{"sslmode" => "require", "password" => "pw"}}] =
             Libpq.parse!(["postgres://u@h/db?pool_size=1", "postgres://u:pw@h/db?ssl=true"])

    assert message =~ "pool_size"
  end

  test "every accepted case reads in libpq as its input does, less the password" do
    cases =
      for {label, input, url, password} <- PgUrlCases.cases(),
          url != :refused,
          do: {label, input, password}

    equivalents = PgUrlCases.libpq_equivalents()

    outputs =
      Enum.map(cases, fn {_label, input, _password} ->
        {:ok, {url, _env}} = PgUrl.split(input)
        url
      end)

    as_written =
      Enum.map(cases, fn {_label, input, _} -> Map.get(equivalents, input, scheme(input)) end)

    for {{{label, input, password}, out}, written} <-
          cases |> Enum.zip(Libpq.parse!(outputs)) |> Enum.zip(Libpq.parse!(as_written)) do
      case written do
        {:ok, expected} ->
          assert {:ok, actual} = out, "#{label}: libpq refuses the output: #{inspect(out)}"
          assert Map.get(actual, "password") in [nil, ""], label
          assert Map.delete(actual, "password") == Map.delete(expected, "password"), label

          if password,
            do: assert(expected["password"] == password, label),
            else: assert(Map.get(expected, "password") in [nil, ""], label)

        {:error, message} ->
          refute Map.has_key?(equivalents, input), "#{label}: its equivalent is unreadable"

          if message =~ "percent-encoded" do
            # libpq refuses the PASSWORD as written (`%zz`, `%00`); it goes
            # to PGPASSWORD literally instead (#2726), and the rest reads.
            assert {:ok, actual} = out, label
            assert Map.get(actual, "password") in [nil, ""], label
          else
            # libpq refuses the input as written (`ssl=1`, `socket_dir`): the
            # output is refused the same way, never made into something else.
            assert out == written, label
          end
      end
    end
  end

  test "an unknown keyword (PASSWORD) is refused by libpq, naming it, never its value" do
    assert [{:error, message}] = Libpq.parse!(["host=db PASSWORD=hunter2 dbname=kiln"])
    assert message =~ "PASSWORD"
    refute message =~ "hunter2"
  end

  test "an accepted conninfo string mentioning `password` reads no password in libpq" do
    for input <- ["host=db dbname=password_reset_svc", "host=db user=passwordless"] do
      assert {:ok, {^input, []}} = PgUrl.split(input)
      assert [{:ok, options}] = Libpq.parse!([input])
      assert Map.get(options, "password") in [nil, ""], input
      assert Map.get(options, "sslpassword") in [nil, ""], input
    end
  end

  test "a translated ssl=false reaches libpq as sslmode=disable" do
    for {_label, input, url, _password} <- PgUrlCases.cases(),
        url != :refused,
        String.contains?(url, "sslmode=disable") do
      assert [{:ok, %{"sslmode" => "disable"}}] = Libpq.parse!([url]), input
    end
  end

  test "every refused case would have put its secret where libpq reads it" do
    refused = for {_label, input, :refused, _} <- PgUrlCases.cases(), do: input
    assert Enum.sort(refused) == Enum.sort(Map.keys(@refused))

    for {input, result} <- Enum.zip(refused, Libpq.parse!(refused)) do
      {key, value} = Map.fetch!(@refused, input)
      assert {:ok, %{^key => ^value}} = result, input
    end
  end

  # The input with its scheme as libpq is given it: `ecto://` as
  # `postgres://`, and a postgres scheme in lower case.
  defp scheme(input) do
    case Regex.run(~r{\A(ecto|postgres|postgresql)://(.*)\z}is, input) do
      [_, scheme, rest] ->
        case String.downcase(scheme) do
          "ecto" -> "postgres://" <> rest
          lower -> lower <> "://" <> rest
        end

      nil ->
        input
    end
  end
end
