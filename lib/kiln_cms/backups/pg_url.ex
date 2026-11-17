defmodule KilnCMS.Backups.PgUrl do
  @moduledoc """
  Turns a `DATABASE_URL`-style string into what libpq (`pg_dump`, `psql`,
  `pg_restore`) accepts, with the password kept out of argv and TLS no weaker
  than the app's own connection.

  ## The URL (`normalize/1`)

  libpq takes a string as a connection URI only when it starts with
  `postgres://` or `postgresql://`, in lower case. `ecto://` is the form Kiln
  documents (`.env.example`, `config/runtime/prod/database.exs`, the compose
  default), and libpq reads it as something else: a database name on the local
  socket, or, once it holds an `=` (`?sslmode=require`), a `key=value` string
  with a syntax error (#2719). `normalize/1` rewrites `ecto://` (any case) to
  `postgres://` and lower-cases a `postgres://` or `postgresql://` scheme.

  It also translates the query parameters Ecto defines and libpq refuses by
  name (`invalid URI query parameter`, #2833). Keys and values are matched
  after percent-decoding, as both libpq and Ecto decode them:

    * `ssl=false` becomes `sslmode=disable`, in place: Ecto reads it as "no
      TLS" for the app's own connection, so the tools connect the same way;
    * `pool_size`, `timeout` and `idle_interval` are dropped (a `?` left with
      nothing after it goes too);
    * everything else, `ssl=true` included (libpq reads it as
      `sslmode=require`), is kept byte for byte. An Ecto option libpq doesn't
      know, such as `socket_dir`, still fails by name: it changes which
      server is reached, so dropping it is not safe.

  ## The password (`split/1`)

  `split/1` then moves the password out of the URL into a `PGPASSWORD`
  environment entry for the child alone (argv is world-readable through
  `/proc/<pid>/cmdline` and `ps`; the environment is not), the way
  `KilnCMS.Backups.RcloneRemote` does for an rclone remote:

    * a userinfo password (`postgres://user:secret@host/db`) is removed from
      the URL and percent-decoded. The userinfo ends where libpq ends it: at
      the first `@` before the first `/`, so `postgres://u:p?ss@h/db` has the
      password `p?ss`. A valid `%HH` becomes its byte; an invalid
      escape and `%00` stay literal rather than raising;
    * a query `password=` (libpq accepts one, and decodes the key, so
      `pass%77ord=` counts) is removed as well. When both
      are present the query value wins, as it does in libpq;
    * everything else (the user, hosts, IPv6 brackets, the path, the other
      query parameters and their order) is kept byte for byte. There is no
      `URI.parse`/`URI.to_string` round trip, which re-encodes.

  A string that is not a `postgres://` or `postgresql://` URI after
  `normalize/1` is refused (#2831) when it mentions `password` (in any case,
  so `sslpassword` too) or holds `://` (another scheme, or a `dbname=` that
  libpq would expand into a URI): its secret would sit in argv for the whole
  dump, and libpq echoes an unreadable one back in its errors. libpq keywords
  are case-sensitive and cannot be quoted, so no secret-bearing `key=value`
  string passes. A passwordless one (`host=/run/postgresql dbname=kiln_prod`)
  and a bare database name pass through unchanged.

      iex> KilnCMS.Backups.PgUrl.split("ecto://kiln:hunter2@db/kiln_prod?sslmode=require")
      {:ok, {"postgres://kiln@db/kiln_prod?sslmode=require", [{"PGPASSWORD", "hunter2"}]}}

  ## TLS (`tls_env/3`)

  The app's Repo encrypts according to `DATABASE_SSL` and
  `DATABASE_SSL_CACERTFILE`; libpq's default (`sslmode=prefer`) silently falls
  back to plaintext and never checks the certificate. `tls_env/3` turns the
  Repo's effective `:ssl` option into `PGSSLMODE` (and `PGSSLROOTCERT`) for
  the child (#2830), unless the URL or the operator's environment already
  says how to connect.

  `scripts/backup.sh`, `scripts/restore.sh` and `scripts/staging.sh` do the
  URL and password part in shell (`pg_conn_split`); the two are tested
  against the same cases. The scripts do not derive TLS settings: cron gets
  them from `sslmode` in its `DATABASE_URL`.
  """

  @typedoc "`[{var, value}]` for the child's environment."
  @type env :: [{String.t(), String.t()}]

  @typedoc """
  Why `split/1` refused a string: it is not a URI libpq reads as one, and it
  carries a password or another URL. The string itself is never in the reason.
  """
  @type refusal :: :refused_conninfo

  # Ecto's own integer options (`@integer_url_query_params` in
  # Ecto.Repo.Supervisor). libpq refuses each by name; none changes which
  # server is reached or how securely.
  @ecto_only ~w(pool_size timeout idle_interval)

  # Query keys (percent-decoded) and conninfo keywords that state how libpq
  # uses TLS. `sslrootcert` counts: with it, libpq verifies even under
  # `sslmode=require`, and `PGSSLMODE=require` with `sslrootcert=system` is
  # refused as a weak mode.
  @tls_keys ~w(sslmode requiressl sslrootcert)

  @doc """
  Rewrites a leading `ecto://` (any case) to `postgres://`, lower-cases a
  `postgres://` or `postgresql://` scheme, and translates Ecto's own query
  parameters (see the moduledoc). Anything else, `nil` included, is returned
  as it is.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(url) when is_binary(url) do
    url = normalize_scheme(url)

    case parse(url) do
      {:ok, %{query: query} = parts} when is_binary(query) ->
        case translate_query(query) do
          ^query -> url
          translated -> assemble(parts.scheme, userinfo_as_written(parts), parts.host, translated)
        end

      _no_query_or_not_a_uri ->
        url
    end
  end

  defp normalize_scheme(url) do
    case String.split(url, "://", parts: 2) do
      [scheme, rest] ->
        case String.downcase(scheme, :ascii) do
          "ecto" -> "postgres://" <> rest
          lower when lower in ["postgres", "postgresql"] -> lower <> "://" <> rest
          _other -> url
        end

      [_no_scheme] ->
        url
    end
  end

  defp translate_query(query) do
    query
    |> String.split("&")
    |> Enum.flat_map(&translate_param/1)
    |> Enum.join("&")
  end

  defp translate_param(param) do
    case String.split(param, "=", parts: 2) do
      [key, value] ->
        case {decode(key), decode(value)} do
          {"ssl", "false"} -> ["sslmode=disable"]
          {key, _value} when key in @ecto_only -> []
          _kept -> [param]
        end

      [_bare] ->
        [param]
    end
  end

  @doc """
  `{:ok, {url, env}}`: the normalized URL with no password in it, and the
  `[{"PGPASSWORD", password}]` entry to run the child with (`[]` when the URL
  has no password to move, so the operator's own `PGPASSWORD` or `.pgpass`
  still applies). `{:error, :refused_conninfo}` for a string whose secret
  would stay in argv (see the moduledoc).
  """
  @spec split(String.t() | nil) :: {:ok, {String.t() | nil, env()}} | {:error, refusal()}
  def split(nil), do: {:ok, {nil, []}}

  def split(url) when is_binary(url) do
    url = normalize(url)

    case parse(url) do
      {:ok, parts} -> {:ok, rebuild(url, parts)}
      :not_a_uri -> if refused?(url), do: {:error, :refused_conninfo}, else: {:ok, {url, []}}
    end
  end

  defp refused?(string) do
    String.contains?(string, "://") or
      string |> String.downcase(:ascii) |> String.contains?("password")
  end

  defp parse(url) do
    case String.split(url, "://", parts: 2) do
      [scheme, rest] when scheme in ["postgres", "postgresql"] ->
        {userinfo, after_userinfo} = split_userinfo(rest)
        {host_and_path, query} = split_query(after_userinfo)
        {:ok, %{scheme: scheme, userinfo: userinfo, host: host_and_path, query: query}}

      _ ->
        :not_a_uri
    end
  end

  # libpq's rule (`conninfo_uri_parse_options` in fe-connect.c): scan from
  # after `//` to the first `@` or `/`. An `@` found first ends the userinfo,
  # so a `?` or `#` before it is part of the password, and an `@` after the
  # first `/` (in the path or query) never is.
  defp split_userinfo(rest) do
    case :binary.match(rest, ["@", "/"]) do
      {pos, 1} when binary_part(rest, pos, 1) == "@" ->
        {binary_part(rest, 0, pos), binary_part(rest, pos + 1, byte_size(rest) - pos - 1)}

      _ ->
        {nil, rest}
    end
  end

  defp split_query(tail) do
    case String.split(tail, "?", parts: 2) do
      [path, query] -> {path, query}
      [path] -> {path, nil}
    end
  end

  defp rebuild(url, parts) do
    {user, userinfo_password} = user_and_password(parts.userinfo)
    {query, query_passwords} = take_query_passwords(parts.query)

    if userinfo_password in [nil, ""] and query_passwords == [] do
      {url, []}
    else
      password = List.last(query_passwords) || userinfo_password
      {assemble(parts.scheme, user, parts.host, query), password_env(decode(password))}
    end
  end

  defp assemble(scheme, user, host, query),
    do: scheme <> "://" <> userinfo(user) <> host <> query_string(query)

  defp userinfo_as_written(%{userinfo: userinfo}), do: userinfo

  defp user_and_password(nil), do: {nil, nil}

  defp user_and_password(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, password] -> {user, password}
      [user] -> {user, nil}
    end
  end

  # Every `password` parameter, in order (libpq keeps the last), and the
  # query without them. libpq percent-decodes keys too, so `pass%77ord=` is
  # one. Untouched when there is none.
  defp take_query_passwords(nil), do: {nil, []}

  defp take_query_passwords(query) do
    {passwords, kept} =
      query
      |> String.split("&")
      |> Enum.split_with(&(param_key(&1) == "password"))

    case passwords do
      [] ->
        {query, []}

      _ ->
        {Enum.join(kept, "&"),
         Enum.map(passwords, &(&1 |> String.split("=", parts: 2) |> List.last()))}
    end
  end

  # The decoded key of a `key=value` query parameter; `nil` without an `=`.
  defp param_key(param) do
    case String.split(param, "=", parts: 2) do
      [key, _value] -> decode(key)
      [_key] -> nil
    end
  end

  defp userinfo(nil), do: ""
  defp userinfo(user), do: user <> "@"

  defp query_string(nil), do: ""
  defp query_string(""), do: ""
  defp query_string(query), do: "?" <> query

  defp password_env(""), do: []
  defp password_env(password), do: [{"PGPASSWORD", password}]

  @doc """
  Whether `url` itself states how libpq uses TLS: a `sslmode`, `requiressl`
  or `sslrootcert` query parameter (keys percent-decoded) of a URI, or the
  same keyword in a `key=value` string. Ecto's `ssl=true` does not count (see
  `tls_env/3`).
  """
  @spec sets_tls?(String.t() | nil) :: boolean()
  def sets_tls?(nil), do: false

  def sets_tls?(url) when is_binary(url) do
    url |> connection_keys() |> Enum.any?(&(&1 in @tls_keys))
  end

  defp connection_keys(url) do
    case parse(url) do
      {:ok, %{query: nil}} -> []
      {:ok, %{query: query}} -> query |> String.split("&") |> Enum.map(&param_key/1)
      :not_a_uri -> conninfo_keys(url)
    end
  end

  # The keywords of a libpq `key=value` string (`conninfo_parse` in
  # fe-connect.c): a keyword runs to whitespace or `=`, and a value is either
  # single-quoted (a backslash escapes the next character) or runs to the
  # next whitespace. A string without `=` is a bare database name and has
  # none. A malformed string stops the scan: libpq refuses it anyway.
  defp conninfo_keys(string) do
    if String.contains?(string, "="), do: conninfo_keys(string, []), else: []
  end

  defp conninfo_keys(string, keys) do
    case skip_space(string) do
      "" ->
        Enum.reverse(keys)

      rest ->
        {key, rest} = take_until(rest, &(&1 in ~c" \t\n\r\f\v="))

        case skip_space(rest) do
          "=" <> value -> conninfo_keys(skip_value(skip_space(value)), [key | keys])
          _malformed -> Enum.reverse([key | keys])
        end
    end
  end

  defp skip_space(<<c, rest::binary>>) when c in ~c" \t\n\r\f\v", do: skip_space(rest)
  defp skip_space(string), do: string

  defp take_until(string, stop?), do: take_until(string, stop?, [])

  defp take_until(<<c, rest::binary>> = string, stop?, acc) do
    if stop?.(c),
      do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), string},
      else: take_until(rest, stop?, [c | acc])
  end

  defp take_until(<<>>, _stop?, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp skip_value("'" <> rest), do: skip_quoted(rest)
  defp skip_value(rest), do: skip_unquoted(rest)

  defp skip_quoted(<<?\\, _escaped, rest::binary>>), do: skip_quoted(rest)
  defp skip_quoted(<<?', rest::binary>>), do: rest
  defp skip_quoted(<<_c, rest::binary>>), do: skip_quoted(rest)
  defp skip_quoted(<<>>), do: ""

  defp skip_unquoted(<<?\\, _escaped, rest::binary>>), do: skip_unquoted(rest)
  defp skip_unquoted(<<c, _::binary>> = rest) when c in ~c" \t\n\r\f\v", do: rest
  defp skip_unquoted(<<_c, rest::binary>>), do: skip_unquoted(rest)
  defp skip_unquoted(<<>>), do: ""

  @doc """
  `{url, env}`: the TLS settings for a libpq child that match the app's own
  connection, as `PGSSLMODE` (and `PGSSLROOTCERT`) entries.

  `ssl` is the Repo's effective `:ssl` option (after Ecto merged the URL's
  `ssl=` into it), read the way Postgrex reads it:

    * `false` or `nil`: nothing (libpq's default applies);
    * a list with `verify: :verify_none`: `sslmode=require` (encrypted, the
      certificate not checked: what Postgrex does);
    * a list verifying the peer with a `cacertfile`: `sslmode=verify-full`
      with that file as `PGSSLROOTCERT`;
    * anything else that is on (`true`, a list verifying the peer against
      `cacerts` or the defaults, a shape this does not know):
      `sslmode=verify-full` against the system's trust store
      (`PGSSLROOTCERT=system`, libpq 16 or later). It fails closed: a
      connection that cannot be verified fails rather than going weaker.

  An explicit choice wins, and then nothing is set: a `sslmode`, `requiressl`
  or `sslrootcert` in the URL (`sets_tls?/1`), or a non-blank `PGSSLMODE` or
  `PGSSLROOTCERT` in `ambient` (the operator's environment, which the child
  inherits). Ecto's `ssl=true` is not such a choice: Ecto ignores it when the
  Repo's `:ssl` is a list, so when the app verifies the server it is dropped
  from the URL and the derived mode applies; otherwise it stays (libpq reads
  it as `sslmode=require`) and nothing is added.
  """
  @spec tls_env(String.t() | nil, term(), %{optional(String.t()) => String.t() | nil}) ::
          {String.t() | nil, env()}
  def tls_env(nil, _ssl, _ambient), do: {nil, []}

  def tls_env(url, ssl, ambient) when is_binary(url) do
    derived = derive_tls(ssl)

    cond do
      derived == [] -> {url, []}
      ambient_tls?(ambient) -> {url, []}
      sets_tls?(url) -> {url, []}
      ssl_true?(url) and match?([{"PGSSLMODE", "require"}], derived) -> {url, []}
      ssl_true?(url) -> {drop_ssl_true(url), derived}
      true -> {url, derived}
    end
  end

  defp derive_tls(ssl) when ssl in [nil, false], do: []

  defp derive_tls(ssl) when is_list(ssl) do
    case Keyword.get(ssl, :verify, :verify_peer) do
      :verify_none -> [{"PGSSLMODE", "require"}]
      _verify_peer -> verify_full(Keyword.get(ssl, :cacertfile))
    end
  end

  defp derive_tls(_true_or_unknown), do: verify_full(nil)

  defp verify_full(cacertfile) do
    root =
      case cacertfile && cacertfile |> to_string() |> String.trim() do
        blank when blank in [nil, ""] -> "system"
        file -> file
      end

    [{"PGSSLMODE", "verify-full"}, {"PGSSLROOTCERT", root}]
  end

  defp ambient_tls?(ambient) do
    Enum.any?(["PGSSLMODE", "PGSSLROOTCERT"], fn var ->
      case Map.get(ambient, var) do
        value when is_binary(value) -> String.trim(value) != ""
        _unset -> false
      end
    end)
  end

  defp ssl_true?(url) do
    case parse(url) do
      {:ok, %{query: query}} when is_binary(query) ->
        query |> String.split("&") |> Enum.any?(&ssl_true_param?/1)

      _ ->
        false
    end
  end

  defp ssl_true_param?(param) do
    case String.split(param, "=", parts: 2) do
      [key, value] -> decode(key) == "ssl" and decode(value) == "true"
      [_bare] -> false
    end
  end

  defp drop_ssl_true(url) do
    {:ok, parts} = parse(url)

    query =
      parts.query
      |> String.split("&")
      |> Enum.reject(&ssl_true_param?/1)
      |> Enum.join("&")

    assemble(parts.scheme, parts.userinfo, parts.host, query)
  end

  # `%HH` to its byte, except `%00` (no C string can carry it) and anything
  # that is not two hex digits, which stay as written. `+` is literal: this is
  # percent-encoding, not form encoding.
  defp decode(string), do: decode(string, [])

  defp decode(<<?%, a, b, rest::binary>>, acc)
       when a in ~c"0123456789abcdefABCDEF" and b in ~c"0123456789abcdefABCDEF" do
    case String.to_integer(<<a, b>>, 16) do
      0 -> decode(rest, [<<?%, a, b>> | acc])
      byte -> decode(rest, [byte | acc])
    end
  end

  defp decode(<<c, rest::binary>>, acc), do: decode(rest, [c | acc])
  defp decode(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
