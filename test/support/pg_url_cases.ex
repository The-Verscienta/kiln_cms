defmodule KilnCMS.Test.PgUrlCases do
  @moduledoc """
  One table of connection strings for `KilnCMS.Backups.PgUrl.split/1` and the
  scripts' shell copy, `pg_conn_split` (#2719, #2726): both are run against it,
  so the app and cron read a `DATABASE_URL` the same way.

  Each case is `{label, input, url, password}`: the URL to give libpq and the
  `PGPASSWORD` to give it (`nil` for none), or `url: :refused` for a string
  that is refused (#2831). `test/kiln_cms/backups/pg_url_libpq_test.exs`
  checks the table against libpq's own parser.
  """

  @doc "The shared cases."
  @spec cases() :: [{String.t(), String.t(), String.t() | :refused, String.t() | nil}]
  def cases do
    [
      {"postgres:// with a password", "postgres://kiln:hunter2@db:5432/kiln",
       "postgres://kiln@db:5432/kiln", "hunter2"},
      {"postgresql:// is a URI too", "postgresql://kiln:hunter2@db/kiln",
       "postgresql://kiln@db/kiln", "hunter2"},
      {"ecto:// with a password", "ecto://kiln:hunter2@db/kiln_prod",
       "postgres://kiln@db/kiln_prod", "hunter2"},
      {"ecto:// without a password", "ecto://kiln@db/kiln_prod", "postgres://kiln@db/kiln_prod",
       nil},
      {"ecto:// without userinfo", "ecto://db/kiln_prod", "postgres://db/kiln_prod", nil},
      {"ECTO:// in capitals", "ECTO://kiln:hunter2@db/kiln_prod", "postgres://kiln@db/kiln_prod",
       "hunter2"},
      {"a percent-encoded password is decoded", "ecto://kiln:p%40ss%3Aw%2Fd%25@db/kiln",
       "postgres://kiln@db/kiln", "p@ss:w/d%"},
      {"a percent-encoded space", "postgres://u:p%40ss%20word@h:5432/db",
       "postgres://u@h:5432/db", "p@ss word"},
      {"`+` stays literal", "postgres://u:a+b@h/db", "postgres://u@h/db", "a+b"},
      {"a malformed escape stays literal", "postgres://u:p%zzx@h/db", "postgres://u@h/db",
       "p%zzx"},
      {"%00 stays literal", "postgres://u:a%00b@h/db", "postgres://u@h/db", "a%00b"},
      {"multibyte UTF-8", "postgres://u:caf%C3%A9@h/db", "postgres://u@h/db", "café"},
      {"a trailing encoded newline is kept", "postgres://u:pw%0A@h/db", "postgres://u@h/db",
       "pw\n"},
      {"an encoded backslash before c", "postgres://u:a%5Ccb@h/db", "postgres://u@h/db", "a\\cb"},
      {"a literal backslash", "postgres://u:a\\cb\\x41@h/db", "postgres://u@h/db", "a\\cb\\x41"},
      {"a colon inside the password", "postgres://u:a:b@h/db", "postgres://u@h/db", "a:b"},
      {"the query is kept byte for byte",
       "ecto://kiln:pw@db/kiln?sslmode=require&connect_timeout=5",
       "postgres://kiln@db/kiln?sslmode=require&connect_timeout=5", "pw"},
      {"a query password is moved", "ecto://kiln@db/kiln?sslmode=require&password=hunter2",
       "postgres://kiln@db/kiln?sslmode=require", "hunter2"},
      {"a query password alone", "postgres://kiln@db/kiln?password=hun%40ter2",
       "postgres://kiln@db/kiln", "hun@ter2"},
      {"a query password first", "postgres://kiln@db/kiln?password=x&sslmode=require&a=1",
       "postgres://kiln@db/kiln?sslmode=require&a=1", "x"},
      {"the query password wins over userinfo, as in libpq",
       "postgres://kiln:fromuserinfo@db/kiln?password=fromquery", "postgres://kiln@db/kiln",
       "fromquery"},
      {"the last query password wins", "postgres://h/db?password=a&password=b", "postgres://h/db",
       "b"},
      {"an empty query password is still removed", "postgres://u:secret@h/db?password=",
       "postgres://u@h/db", nil},
      {"an `@` in the query is not userinfo", "postgres://u:p@h/db?application_name=a@b",
       "postgres://u@h/db?application_name=a@b", "p"},
      # The userinfo ends where libpq's URI parser (`conninfo_uri_parse_options`
      # in fe-connect.c) ends it: at the FIRST `@` before the first `/`. So an
      # unencoded `@` in a password splits it, and a `?` or `#` before the `@`
      # belongs to the password.
      {"an unencoded `@` in the password: the first `@` ends the userinfo",
       "postgres://u:p@ss@h/db", "postgres://u@ss@h/db", "p"},
      {"a `?` before the `@` is part of the password", "postgres://u:p?ss@h/db",
       "postgres://u@h/db", "p?ss"},
      {"a `#` before the `@` is part of the password", "postgres://u:p#ss@h/db",
       "postgres://u@h/db", "p#ss"},
      {"no path, an `@` in the query", "postgres://u:p@h?application_name=a@b",
       "postgres://u@h?application_name=a@b", "p"},
      {"a `/` before any `@` means no userinfo", "postgres://h/db?password=x@y&a=b@c",
       "postgres://h/db?a=b@c", "x@y"},
      {"a percent-encoded query key is decoded, as libpq does",
       "postgres://kiln@db/kiln?pass%77ord=x&sslmode=require",
       "postgres://kiln@db/kiln?sslmode=require", "x"},
      {"a key that decodes to something else is kept", "postgres://u@h/db?pass%2577ord=x",
       "postgres://u@h/db?pass%2577ord=x", nil},
      {"an IPv6 host", "ecto://u:pw@[::1]:5432/db", "postgres://u@[::1]:5432/db", "pw"},
      {"several hosts", "postgres://u:pw@h1:5432,h2:5433/db?target_session_attrs=read-write",
       "postgres://u@h1:5432,h2:5433/db?target_session_attrs=read-write", "pw"},
      {"no path", "postgres://u:pw@h", "postgres://u@h", "pw"},
      {"no path, a query", "postgres://u:pw@h?sslmode=require", "postgres://u@h?sslmode=require",
       "pw"},
      {"an empty user before `@`", "postgres://@h/db?password=pw", "postgres://@h/db", "pw"},
      {"a fragment ends the authority", "postgres://u:pw@h#frag", "postgres://u@h#frag", "pw"},
      {"no password", "postgres://u@h:5432/db", "postgres://u@h:5432/db", nil},
      {"an empty password is left as written", "postgres://u:@h/db", "postgres://u:@h/db", nil},
      {"a socket directory in the query", "postgres:///db?host=/var/run/postgresql",
       "postgres:///db?host=/var/run/postgresql", nil},
      {"an empty string", "", "", nil},
      # Schemes (#2831): libpq reads only lower-case postgres:// and
      # postgresql:// as URIs, and anything else as a database name, password
      # and all.
      {"POSTGRES:// in capitals", "POSTGRES://kiln:hunter2@db/kiln", "postgres://kiln@db/kiln",
       "hunter2"},
      {"PostgreSQL:// in mixed case", "PostgreSQL://kiln:hunter2@db/kiln",
       "postgresql://kiln@db/kiln", "hunter2"},
      {"another scheme is refused", "mysql://u:pw@h/db", :refused, nil},
      {"a leading space is not a URI, and is refused", " postgres://u:pw@h/db", :refused, nil},
      # key=value strings (#2831): refused when a keyword is `password` or
      # `sslpassword`, or they hold a URL; libpq keywords are case-sensitive
      # and cannot be quoted.
      {"a conninfo string with a password is refused", "host=db password=x dbname=kiln", :refused,
       nil},
      {"a quoted conninfo password is refused", "host=db password='a b\\'c' dbname=kiln",
       :refused, nil},
      {"a conninfo sslpassword is refused", "host=db sslpassword=x dbname=kiln", :refused, nil},
      {"a conninfo password alone is refused", "password=x", :refused, nil},
      {"spaces around `=` still make a password keyword", "host=db password = x", :refused, nil},
      {"a keyword straight after a closing quote is refused", "host='x'password=y dbname=kiln",
       :refused, nil},
      # Not a libpq keyword (they are case-sensitive): libpq refuses the
      # string by naming `PASSWORD`, without echoing its value
      # (pg_url_libpq_test.exs), so it is passed through.
      {"PASSWORD in capitals is libpq's to refuse", "host=db PASSWORD=hunter2 dbname=kiln",
       "host=db PASSWORD=hunter2 dbname=kiln", nil},
      {"`password` inside a value is not a keyword", "host=db dbname=password_reset_svc",
       "host=db dbname=password_reset_svc", nil},
      {"`password` at the start of a value is not a keyword", "host=db user=passwordless",
       "host=db user=passwordless", nil},
      {"a dbname that libpq would expand into a URI is refused", "dbname='postgres://u:s@h/db'",
       :refused, nil},
      {"a passwordless conninfo string is kept", "host=/run/postgresql dbname=kiln_prod",
       "host=/run/postgresql dbname=kiln_prod", nil},
      {"a bare database name is kept", "kiln_prod", "kiln_prod", nil},
      # Ecto's own query parameters (#2833), matched percent-decoded.
      {"ssl=false becomes sslmode=disable", "ecto://kiln:pw@db/kiln?ssl=false",
       "postgres://kiln@db/kiln?sslmode=disable", "pw"},
      {"ssl=false in the middle",
       "postgres://kiln:pw@db/kiln?connect_timeout=5&ssl=false&application_name=b",
       "postgres://kiln@db/kiln?connect_timeout=5&sslmode=disable&application_name=b", "pw"},
      {"ssl=false last", "postgres://kiln:pw@db/kiln?application_name=x&ssl=false",
       "postgres://kiln@db/kiln?application_name=x&sslmode=disable", "pw"},
      {"an encoded ssl=false", "postgres://kiln:pw@db/kiln?%73sl=%66alse",
       "postgres://kiln@db/kiln?sslmode=disable", "pw"},
      {"ssl=false without a password", "postgres://kiln@db/kiln?ssl=false",
       "postgres://kiln@db/kiln?sslmode=disable", nil},
      {"ssl=false and a query password", "postgres://kiln@db/kiln?ssl=false&password=hunter2",
       "postgres://kiln@db/kiln?sslmode=disable", "hunter2"},
      {"ssl=true is kept (libpq reads it)", "postgres://kiln:pw@db/kiln?ssl=true",
       "postgres://kiln@db/kiln?ssl=true", "pw"},
      {"ssl=1 is kept (libpq refuses it, by name)", "postgres://kiln:pw@db/kiln?ssl=1",
       "postgres://kiln@db/kiln?ssl=1", "pw"},
      {"ssl=FALSE is not Ecto's false, and is kept", "postgres://kiln@db/kiln?ssl=FALSE",
       "postgres://kiln@db/kiln?ssl=FALSE", nil},
      {"pool_size, timeout and idle_interval are dropped",
       "ecto://kiln:pw@db/kiln?pool_size=10&sslmode=require&timeout=5000&idle_interval=1000",
       "postgres://kiln@db/kiln?sslmode=require", "pw"},
      {"a query of Ecto options alone goes, `?` and all",
       "postgres://kiln:pw@db/kiln?pool_size=10", "postgres://kiln@db/kiln", "pw"},
      {"an Ecto option without a password", "postgres://kiln@db/kiln?pool_size=10",
       "postgres://kiln@db/kiln", nil},
      {"an Ecto option beside an empty password keeps the userinfo",
       "postgres://kiln:@db/kiln?pool_size=10", "postgres://kiln:@db/kiln", nil},
      {"an encoded Ecto key is dropped", "postgres://kiln:pw@db/kiln?pool%5Fsize=10",
       "postgres://kiln@db/kiln", "pw"},
      {"socket_dir is kept: it changes which server is reached",
       "ecto://kiln:pw@localhost/kiln?socket_dir=/run/postgresql",
       "postgres://kiln@localhost/kiln?socket_dir=/run/postgresql", "pw"}
    ]
  end

  @doc """
  What the scripts' `PG_CONN_DISPLAY_URL` is where it differs from the URL
  given to libpq: the query as written, untranslated, for printing or for an
  app's `DATABASE_URL`. Everywhere else the two are the same.
  """
  @spec display_urls() :: %{String.t() => String.t()}
  def display_urls do
    %{
      "ecto://kiln:pw@db/kiln?ssl=false" => "postgres://kiln@db/kiln?ssl=false",
      "postgres://kiln:pw@db/kiln?connect_timeout=5&ssl=false&application_name=b" =>
        "postgres://kiln@db/kiln?connect_timeout=5&ssl=false&application_name=b",
      "postgres://kiln:pw@db/kiln?application_name=x&ssl=false" =>
        "postgres://kiln@db/kiln?application_name=x&ssl=false",
      "postgres://kiln:pw@db/kiln?%73sl=%66alse" => "postgres://kiln@db/kiln?%73sl=%66alse",
      "postgres://kiln@db/kiln?ssl=false" => "postgres://kiln@db/kiln?ssl=false",
      "postgres://kiln@db/kiln?ssl=false&password=hunter2" => "postgres://kiln@db/kiln?ssl=false",
      "ecto://kiln:pw@db/kiln?pool_size=10&sslmode=require&timeout=5000&idle_interval=1000" =>
        "postgres://kiln@db/kiln?pool_size=10&sslmode=require&timeout=5000&idle_interval=1000",
      "postgres://kiln:pw@db/kiln?pool_size=10" => "postgres://kiln@db/kiln?pool_size=10",
      "postgres://kiln@db/kiln?pool_size=10" => "postgres://kiln@db/kiln?pool_size=10",
      "postgres://kiln:@db/kiln?pool_size=10" => "postgres://kiln:@db/kiln?pool_size=10",
      "postgres://kiln:pw@db/kiln?pool%5Fsize=10" => "postgres://kiln@db/kiln?pool%5Fsize=10"
    }
  end

  @doc """
  For the cases whose input libpq cannot read as written (Ecto's own
  parameters), the URL libpq should read the same way as the output, password
  included: what the translation is meant to produce.
  """
  @spec libpq_equivalents() :: %{String.t() => String.t()}
  def libpq_equivalents do
    %{
      "ecto://kiln:pw@db/kiln?ssl=false" => "postgres://kiln:pw@db/kiln?sslmode=disable",
      "postgres://kiln:pw@db/kiln?connect_timeout=5&ssl=false&application_name=b" =>
        "postgres://kiln:pw@db/kiln?connect_timeout=5&sslmode=disable&application_name=b",
      "postgres://kiln:pw@db/kiln?application_name=x&ssl=false" =>
        "postgres://kiln:pw@db/kiln?application_name=x&sslmode=disable",
      "postgres://kiln:pw@db/kiln?%73sl=%66alse" => "postgres://kiln:pw@db/kiln?sslmode=disable",
      "postgres://kiln@db/kiln?ssl=false" => "postgres://kiln@db/kiln?sslmode=disable",
      "postgres://kiln@db/kiln?ssl=false&password=hunter2" =>
        "postgres://kiln:hunter2@db/kiln?sslmode=disable",
      "ecto://kiln:pw@db/kiln?pool_size=10&sslmode=require&timeout=5000&idle_interval=1000" =>
        "postgres://kiln:pw@db/kiln?sslmode=require",
      "postgres://kiln:pw@db/kiln?pool_size=10" => "postgres://kiln:pw@db/kiln",
      "postgres://kiln@db/kiln?pool_size=10" => "postgres://kiln@db/kiln",
      "postgres://kiln:@db/kiln?pool_size=10" => "postgres://kiln:@db/kiln",
      "postgres://kiln:pw@db/kiln?pool%5Fsize=10" => "postgres://kiln:pw@db/kiln"
    }
  end

  @doc """
  `{url, sets_tls?}`: whether the string itself chooses libpq's sslmode
  (`KilnCMS.Backups.PgUrl.sets_tls?/1`), so the app adds no `PGSSLMODE`. A
  root certificate alone does not.
  """
  @spec tls_cases() :: [{String.t(), boolean()}]
  def tls_cases do
    [
      {"postgres://u@h/db", false},
      {"postgres://u@h/db?sslmode=require", true},
      {"postgres://u@h/db?a=1&sslmode=disable", true},
      {"postgres://u@h/db?%73slmode=verify-full", true},
      {"postgres://u@h/db?requiressl=1", true},
      {"postgres://u@h/db?sslrootcert=/ca.pem", false},
      {"postgres://u@h/db?ssl=true", false},
      {"postgres://u@h/db?sslcert=/c.pem&sslkey=/k.pem", false},
      {"postgres://u@h/db?application_name=sslmode=x", false},
      {"postgres://u@h/db?sslmode", false},
      {"host=db dbname=kiln sslmode=require", true},
      {"host=db sslmode = verify-full dbname=kiln", true},
      {"host=db requiressl=1", true},
      {"host=db sslrootcert='/etc/a b.pem'", false},
      {"host=db application_name='x sslmode=disable' dbname=kiln", false},
      {"host=db application_name=x\\ sslmode=disable dbname=kiln", false},
      {"host=db dbname=kiln", false},
      {"kiln_prod", false},
      {"", false}
    ]
  end
end
