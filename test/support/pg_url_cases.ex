defmodule KilnCMS.Test.PgUrlCases do
  @moduledoc """
  One table of connection strings for `KilnCMS.Backups.PgUrl.split/1` and the
  scripts' shell copy, `pg_conn_split` (#2719, #2726): both are run against it,
  so the app and cron read a `DATABASE_URL` the same way.

  Each case is `{label, input, url, password}`: the URL to give libpq and the
  `PGPASSWORD` to give it (`nil` for none).
  """

  @doc "The shared cases."
  @spec cases() :: [{String.t(), String.t(), String.t(), String.t() | nil}]
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
      {"an `@` in the password, unencoded", "postgres://u:p@ss@h/db", "postgres://u@h/db",
       "p@ss"},
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
      {"a conninfo string is not touched", "host=db password=x dbname=kiln",
       "host=db password=x dbname=kiln", nil},
      {"another scheme is not touched", "mysql://u:pw@h/db", "mysql://u:pw@h/db", nil},
      {"an empty string", "", "", nil}
    ]
  end
end
