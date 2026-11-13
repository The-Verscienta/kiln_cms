defmodule KilnCMS.Backups.PgUrl do
  @moduledoc """
  Turns a `DATABASE_URL`-style string into what libpq (`pg_dump`, `psql`,
  `pg_restore`) accepts, with the password kept out of argv.

  libpq takes a string as a connection URI only when it starts with
  `postgres://` or `postgresql://`. `ecto://` is the form Kiln documents
  (`.env.example`, `config/runtime/prod/database.exs`, the compose default),
  and libpq reads it as something else: a database name on the local socket,
  or, once it holds an `=` (`?sslmode=require`), a `key=value` string with a
  syntax error (#2719). `normalize/1` rewrites the scheme and nothing else.

  `split/1` then moves the password out of the URL into a `PGPASSWORD`
  environment entry for the child alone (argv is world-readable through
  `/proc/<pid>/cmdline` and `ps`; the environment is not), the way
  `KilnCMS.Backups.RcloneRemote` does for an rclone remote:

    * a userinfo password (`postgres://user:secret@host/db`) is removed from
      the URL and percent-decoded. A valid `%HH` becomes its byte; an invalid
      escape and `%00` stay literal rather than raising;
    * a query `password=` (libpq accepts one) is removed as well. When both
      are present the query value wins, as it does in libpq;
    * everything else (the user, hosts, IPv6 brackets, the path, the other
      query parameters and their order) is kept byte for byte. There is no
      `URI.parse`/`URI.to_string` round trip, which re-encodes.

  A `key=value` conninfo string, or any scheme libpq would not read as a URI,
  is returned unchanged with no environment. Ecto-only query parameters
  (`ssl=true`, `pool_size=10`) are not translated: libpq refuses them by name,
  and the fix is to set `BACKUP_DATABASE_URL`.

  `scripts/backup.sh`, `scripts/restore.sh` and `scripts/staging.sh` do the
  same in shell (`pg_conn_split`); the two are tested against the same cases.
  """

  @doc """
  Rewrites a leading `ecto://` (any case) to `postgres://`. Anything else,
  `nil` included, is returned as it is.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(<<scheme::binary-size(7), rest::binary>> = url) do
    if String.downcase(scheme) == "ecto://", do: "postgres://" <> rest, else: url
  end

  def normalize(url), do: url

  @doc """
  `{url, env}`: the normalized URL with no password in it, and the
  `[{"PGPASSWORD", password}]` entry to run the child with (`[]` when the URL
  has no password to move, so the operator's own `PGPASSWORD` or `.pgpass`
  still applies).
  """
  @spec split(String.t() | nil) :: {String.t() | nil, [{String.t(), String.t()}]}
  def split(nil), do: {nil, []}

  def split(url) when is_binary(url) do
    url = normalize(url)

    case parse(url) do
      {:ok, parts} -> rebuild(url, parts)
      :not_a_uri -> {url, []}
    end
  end

  defp parse(url) do
    case String.split(url, "://", parts: 2) do
      [scheme, rest] when scheme in ["postgres", "postgresql"] ->
        # The authority runs to the first `/`, `?` or `#`; userinfo ends at the
        # LAST `@` inside it, so an `@` in the query is never mistaken for one.
        {authority, tail} = split_at(rest, ["/", "?", "#"])
        {userinfo, host} = split_userinfo(authority)
        {path, query} = split_query(tail)
        {:ok, %{scheme: scheme, userinfo: userinfo, host: host, path: path, query: query}}

      _ ->
        :not_a_uri
    end
  end

  defp split_at(string, separators) do
    case :binary.match(string, separators) do
      {pos, _} -> {binary_part(string, 0, pos), binary_part(string, pos, byte_size(string) - pos)}
      :nomatch -> {string, ""}
    end
  end

  defp split_userinfo(authority) do
    case :binary.matches(authority, "@") do
      [] ->
        {nil, authority}

      matches ->
        {pos, 1} = List.last(matches)

        {binary_part(authority, 0, pos),
         binary_part(authority, pos + 1, byte_size(authority) - pos - 1)}
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

      stripped =
        parts.scheme <>
          "://" <> userinfo(user) <> parts.host <> parts.path <> query_string(query)

      {stripped, password_env(decode(password))}
    end
  end

  defp user_and_password(nil), do: {nil, nil}

  defp user_and_password(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, password] -> {user, password}
      [user] -> {user, nil}
    end
  end

  # Every `password=` parameter, in order (libpq keeps the last), and the
  # query without them. Untouched when there is none.
  defp take_query_passwords(nil), do: {nil, []}

  defp take_query_passwords(query) do
    {passwords, kept} =
      query
      |> String.split("&")
      |> Enum.split_with(&String.starts_with?(&1, "password="))

    case passwords do
      [] ->
        {query, []}

      _ ->
        {Enum.join(kept, "&"), Enum.map(passwords, &String.replace_prefix(&1, "password=", ""))}
    end
  end

  defp userinfo(nil), do: ""
  defp userinfo(user), do: user <> "@"

  defp query_string(nil), do: ""
  defp query_string(""), do: ""
  defp query_string(query), do: "?" <> query

  defp password_env(""), do: []
  defp password_env(password), do: [{"PGPASSWORD", password}]

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
