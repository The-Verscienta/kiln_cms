defmodule KilnCMS.Backups.PgUrlTest do
  @moduledoc """
  `KilnCMS.Backups.PgUrl` (#2719, #2726, #2830, #2831, #2833): a
  `DATABASE_URL` as libpq reads it, with the password moved out of argv, a
  secret-bearing `key=value` string or a URI with `sslpassword` (#3049) refused, Ecto's own query parameters
  translated, and TLS settings that follow the app's Repo.

  The same table drives the shell copy (`pg_conn_split`) in
  `test/scripts/pg_conn_split_test.exs`, so the two cannot drift apart, and
  `pg_url_libpq_test.exs` checks it against libpq's own parser.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.PgUrl

  @cases KilnCMS.Test.PgUrlCases.cases()

  describe "split/1" do
    for {label, input, url, password} <- @cases do
      @input input
      @expected (if is_atom(url) do
                   {:error, url}
                 else
                   {:ok, {url, if(password, do: [{"PGPASSWORD", password}], else: [])}}
                 end)

      test label do
        assert PgUrl.split(@input) == @expected
      end
    end

    test "nil" do
      assert PgUrl.split(nil) == {:ok, {nil, []}}
    end

    test "never raises, whatever follows a `%`" do
      for tail <- ["%", "%z", "%zz", "%0", "%%", "%g0", "%00"] do
        assert {:ok, {"postgres://u@h/db", [{"PGPASSWORD", "p" <> ^tail}]}} =
                 PgUrl.split("postgres://u:p#{tail}@h/db")
      end
    end

    test "a refusal never carries the string it refused" do
      for input <- [
            "host=db password=hunter2 dbname=kiln",
            "postgres://u@h/db?sslpassword=hunter2"
          ] do
        assert {:error, reason} = PgUrl.split(input)
        refute inspect(reason) =~ "hunter2"
      end
    end
  end

  describe "normalize/1" do
    test "rewrites the ecto scheme, in any case, and lower-cases postgres schemes" do
      assert PgUrl.normalize("ecto://u:p%40@h/db?sslmode=require") ==
               "postgres://u:p%40@h/db?sslmode=require"

      assert PgUrl.normalize("Ecto://h/db") == "postgres://h/db"
      assert PgUrl.normalize("POSTGRES://h/db") == "postgres://h/db"
      assert PgUrl.normalize("postgreSQL://h/db") == "postgresql://h/db"
      assert PgUrl.normalize("postgresql://h/db") == "postgresql://h/db"
      assert PgUrl.normalize("host=db dbname=kiln") == "host=db dbname=kiln"
      assert PgUrl.normalize("ecto:/h/db") == "ecto:/h/db"
      assert PgUrl.normalize("mysql://u:pw@h/db") == "mysql://u:pw@h/db"
      assert PgUrl.normalize("") == ""
      assert PgUrl.normalize(nil) == nil
    end

    test "translates Ecto's query parameters and keeps the password where it was" do
      assert PgUrl.normalize("ecto://u:p%40@h/db?ssl=false&pool_size=5") ==
               "postgres://u:p%40@h/db?sslmode=disable"

      assert PgUrl.normalize("postgres://u@h/db?password=x&timeout=5&ssl=true") ==
               "postgres://u@h/db?password=x&ssl=true"
    end

    test "leaves a URL with nothing to translate byte for byte, `?` and all" do
      for url <- ["postgres://h/db?", "postgres://h/db?a=1&&b=2", "postgres://h/db?ssl"] do
        assert PgUrl.normalize(url) == url
      end
    end
  end

  describe "sets_tls?/1" do
    for {url, sets?} <- KilnCMS.Test.PgUrlCases.tls_cases() do
      @url url
      @sets sets?

      test "#{inspect(url)} -> #{sets?}" do
        assert PgUrl.sets_tls?(@url) == @sets
      end
    end

    test "nil" do
      refute PgUrl.sets_tls?(nil)
    end
  end

  describe "tls_env/3" do
    @url "postgres://kiln@db/kiln"
    @none %{}

    test "no TLS in the Repo adds nothing" do
      for ssl <- [nil, false] do
        assert PgUrl.tls_env(@url, ssl, @none) == {@url, []}
      end
    end

    test "verify_none (DATABASE_SSL on, no CA file) requires TLS" do
      assert PgUrl.tls_env(@url, [verify: :verify_none], @none) ==
               {@url, [{"PGSSLMODE", "require"}]}
    end

    test "a CA file (DATABASE_SSL_CACERTFILE) verifies the server against it" do
      ssl = [verify: :verify_peer, cacertfile: "/etc/kiln/ca.pem", depth: 3]

      assert PgUrl.tls_env(@url, ssl, @none) ==
               {@url, [{"PGSSLMODE", "verify-full"}, {"PGSSLROOTCERT", "/etc/kiln/ca.pem"}]}

      assert PgUrl.tls_env(@url, [verify: :verify_peer, cacertfile: ~c"/ca.pem"], @none) ==
               {@url, [{"PGSSLMODE", "verify-full"}, {"PGSSLROOTCERT", "/ca.pem"}]}
    end

    test "any other way of verifying fails closed: verify-full against the system store" do
      system = {@url, [{"PGSSLMODE", "verify-full"}, {"PGSSLROOTCERT", "system"}]}

      for ssl <- [
            true,
            [],
            [verify: :verify_peer],
            [verify: :verify_peer, cacerts: [<<1, 2, 3>>]],
            [verify: :verify_peer, cacertfile: "  "],
            :something_new
          ] do
        assert PgUrl.tls_env(@url, ssl, @none) == system, inspect(ssl)
      end
    end

    test "a TLS key in the URL wins, and nothing is added" do
      for {url, true} <- KilnCMS.Test.PgUrlCases.tls_cases(),
          ssl <- [[verify: :verify_none], [verify: :verify_peer, cacertfile: "/ca.pem"]] do
        assert PgUrl.tls_env(url, ssl, @none) == {url, []}, url
      end
    end

    test "the operator's own PGSSLMODE wins, and nothing is added" do
      ssl = [verify: :verify_peer, cacertfile: "/ca.pem"]

      for ambient <- [
            %{"PGSSLMODE" => "disable"},
            %{"PGSSLMODE" => "require", "PGSSLROOTCERT" => "/other.pem"}
          ] do
        assert PgUrl.tls_env(@url, ssl, ambient) == {@url, []}
      end

      for blank <- [
            %{"PGSSLMODE" => ""},
            %{"PGSSLMODE" => "  ", "PGSSLROOTCERT" => nil},
            %{"PGSSLROOTCERT" => " "}
          ] do
        assert PgUrl.tls_env(@url, ssl, blank) ==
                 {@url, [{"PGSSLMODE", "verify-full"}, {"PGSSLROOTCERT", "/ca.pem"}]}
      end
    end

    # A root certificate is not an sslmode: alone it leaves libpq on
    # `prefer`, which falls back to cleartext. The mode is still set; the
    # operator's root certificate is kept.
    test "a root certificate alone still gets the derived mode, and is kept" do
      require = [verify: :verify_none]
      verify = [verify: :verify_peer, cacertfile: "/ca.pem"]

      for {url, ambient} <- [
            {@url, %{"PGSSLROOTCERT" => "/other.pem"}},
            {"postgres://kiln@db/kiln?sslrootcert=/other.pem", @none},
            {"postgres://kiln@db/kiln?%73slrootcert=/other.pem", @none},
            {"host=db dbname=kiln sslrootcert='/etc/a b.pem'", @none}
          ] do
        assert PgUrl.tls_env(url, require, ambient) == {url, [{"PGSSLMODE", "require"}]}, url
        assert PgUrl.tls_env(url, verify, ambient) == {url, [{"PGSSLMODE", "verify-full"}]}, url
        assert PgUrl.tls_env(url, true, ambient) == {url, [{"PGSSLMODE", "verify-full"}]}, url
      end
    end

    # libpq refuses `sslmode=require` with `sslrootcert=system` ("weak
    # sslmode"); verify-full is the mode that works and is not weaker.
    test "a `system` root certificate turns require into verify-full" do
      for {url, ambient} <- [
            {@url, %{"PGSSLROOTCERT" => "system"}},
            {"postgres://kiln@db/kiln?sslrootcert=system", @none},
            {"postgres://kiln@db/kiln?sslrootcert=system", %{"PGSSLROOTCERT" => "/other.pem"}},
            {"host=db sslrootcert=system", @none}
          ] do
        assert PgUrl.tls_env(url, [verify: :verify_none], ambient) ==
                 {url, [{"PGSSLMODE", "verify-full"}]},
               url
      end

      # The URL's root certificate beats the environment's, as in libpq.
      url = "postgres://kiln@db/kiln?sslrootcert=/other.pem"

      assert PgUrl.tls_env(url, [verify: :verify_none], %{"PGSSLROOTCERT" => "system"}) ==
               {url, [{"PGSSLMODE", "require"}]}
    end

    test "with a root certificate, ssl=true stays for require and goes for verify-full" do
      url = "postgres://kiln@db/kiln?ssl=true&sslrootcert=/other.pem"
      assert PgUrl.tls_env(url, [verify: :verify_none], @none) == {url, []}

      assert PgUrl.tls_env(url, true, @none) ==
               {"postgres://kiln@db/kiln?sslrootcert=/other.pem", [{"PGSSLMODE", "verify-full"}]}

      system = "postgres://kiln@db/kiln?ssl=true&sslrootcert=system"

      assert PgUrl.tls_env(system, [verify: :verify_none], @none) ==
               {"postgres://kiln@db/kiln?sslrootcert=system", [{"PGSSLMODE", "verify-full"}]}
    end

    test "a root certificate with no TLS in the Repo still adds nothing" do
      assert PgUrl.tls_env(@url, false, %{"PGSSLROOTCERT" => "system"}) == {@url, []}
    end

    test "ssl=true never makes it weaker than the Repo: dropped when the Repo verifies" do
      url = "postgres://kiln@db/kiln?a=1&ssl=true&b=2"

      assert PgUrl.tls_env(url, [verify: :verify_peer, cacertfile: "/ca.pem"], @none) ==
               {"postgres://kiln@db/kiln?a=1&b=2",
                [{"PGSSLMODE", "verify-full"}, {"PGSSLROOTCERT", "/ca.pem"}]}

      assert PgUrl.tls_env("postgres://kiln@db/kiln?%73sl=%74rue", true, @none) ==
               {"postgres://kiln@db/kiln",
                [{"PGSSLMODE", "verify-full"}, {"PGSSLROOTCERT", "system"}]}
    end

    test "ssl=true stays when the Repo only requires TLS, or has none" do
      url = "postgres://kiln@db/kiln?ssl=true"

      assert PgUrl.tls_env(url, [verify: :verify_none], @none) == {url, []}
      assert PgUrl.tls_env(url, false, @none) == {url, []}
    end

    test "a passwordless key=value string and a bare name get the derived mode" do
      for url <- ["host=db dbname=kiln", "kiln_prod"] do
        assert PgUrl.tls_env(url, [verify: :verify_none], @none) ==
                 {url, [{"PGSSLMODE", "require"}]}
      end
    end

    test "nil" do
      assert PgUrl.tls_env(nil, true, @none) == {nil, []}
    end
  end
end
