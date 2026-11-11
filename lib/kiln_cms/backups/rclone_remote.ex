defmodule KilnCMS.Backups.RcloneRemote do
  @moduledoc """
  Keeps the credentials of a connection-string `BACKUP_RCLONE_REMOTE` out of
  `rclone`'s argv (#2690).

  rclone accepts a remote's whole configuration inline, as a connection string:

      :s3,provider=Cloudflare,access_key_id=AKIA…,secret_access_key=…:kiln-backups
      r2,secret_access_key=…:kiln-backups

  Passed as-is, that is an argv element of every `rclone copy` for the whole
  transfer, and argv is not private: `/proc/<pid>/cmdline` is world-readable
  (0444, unlike `environ`'s 0400), the host's `ps` shows a container's argv,
  and process-monitoring agents scrape it. `split_credentials/1` moves the
  parameters into `RCLONE_CONFIG_<NAME>_<KEY>` environment entries for the
  child alone, the same way `KilnCMS.Backups.Steps.split_credentials/1` moves
  the database password into `PGPASSWORD`, and leaves rclone a bare
  `<name>:<path>`:

    * `:backend,k=v,…:path` becomes the remote `kiln_offsite:path`, with
      `RCLONE_CONFIG_KILN_OFFSITE_TYPE=backend` and one entry per parameter;
    * `name,k=v,…:path` becomes `name:path` with one entry per parameter.
      A remote-specific variable overrides the same key in rclone's config
      file, just as the inline parameter did. A name rclone could not look up
      as a variable (anything but letters, digits and `_`) is left as it was.

  A parameter without `=` is `true`, as in rclone. A quoted value (`'…'` or
  `"…"`, a doubled quote standing for itself) may hold `,` and `:`.

  Anything else — a named remote with no parameters (`r2:kiln-backups`), a
  local path, a string this parser does not recognize — is returned unchanged
  with no environment. A string rclone itself cannot parse fails in rclone, and
  its output goes through `KilnCMS.Backups.Redact` like any other.

  `scripts/backup.sh` does the same translation in shell (`rclone_split_remote`);
  the two are tested against the same cases.
  """

  # The name an inline `:backend,…` remote gets. Distinctive enough not to
  # meet a section of an operator's rclone.conf by accident.
  @alias "kiln_offsite"

  @doc """
  `{remote, env}`: the remote to give rclone as an argument, and the
  `[{var, value}]` environment entries that configure it.
  """
  @spec split_credentials(String.t()) :: {String.t(), [{String.t(), String.t()}]}
  def split_credentials(remote) when is_binary(remote) do
    case parse(remote) do
      {:ok, name, params, path} -> {name <> ":" <> path, env(name, params)}
      :unchanged -> {remote, []}
    end
  end

  defp parse(":" <> rest) do
    with {:ok, backend, "," <> rest} <- take_name(rest),
         true <- env_safe?(backend),
         {:ok, params, path} <- params(rest, []) do
      {:ok, @alias, [{"type", backend} | params], path}
    else
      _ -> :unchanged
    end
  end

  defp parse(remote) do
    with {:ok, name, "," <> rest} <- take_name(remote),
         true <- env_safe?(name),
         {:ok, params, path} <- params(rest, []) do
      {:ok, name, params, path}
    else
      _ -> :unchanged
    end
  end

  # The name runs to the first `,` or `:`; with neither it is a local path.
  defp take_name(string) do
    case :binary.match(string, [",", ":"]) do
      {pos, 1} when pos > 0 ->
        {:ok, binary_part(string, 0, pos), binary_part(string, pos, byte_size(string) - pos)}

      _ ->
        :error
    end
  end

  defp env_safe?(name), do: name =~ ~r/\A[A-Za-z0-9_]+\z/

  # `key[=value]` items separated by `,`, ended by the `:` before the path.
  defp params(string, acc) do
    case Regex.run(~r/\A([A-Za-z0-9_-]+)(=?)/, string) do
      [whole, key, eq] ->
        rest = binary_part(string, byte_size(whole), byte_size(string) - byte_size(whole))

        with {:ok, value, rest} <- param_value(eq, rest),
             do: next_param(rest, [{key, value} | acc])

      nil ->
        :error
    end
  end

  # A key without `=` is a boolean flag, as in rclone.
  defp param_value("=", rest), do: value(rest)
  defp param_value("", rest), do: {:ok, "true", rest}

  defp next_param("," <> rest, acc), do: params(rest, acc)
  defp next_param(":" <> path, acc), do: {:ok, Enum.reverse(acc), path}
  defp next_param(_rest, _acc), do: :error

  defp value(<<q, rest::binary>>) when q in [?", ?'], do: quoted(rest, q, [])

  defp value(string) do
    case :binary.match(string, [",", ":"]) do
      {pos, 1} ->
        {:ok, binary_part(string, 0, pos), binary_part(string, pos, byte_size(string) - pos)}

      :nomatch ->
        :error
    end
  end

  defp quoted(<<q, q, rest::binary>>, q, acc), do: quoted(rest, q, [q | acc])

  defp quoted(<<q, rest::binary>>, q, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp quoted(<<c, rest::binary>>, q, acc), do: quoted(rest, q, [c | acc])
  defp quoted(<<>>, _q, _acc), do: :error

  defp env(name, params) do
    prefix = "RCLONE_CONFIG_" <> String.upcase(name) <> "_"

    for {key, value} <- params,
        do: {prefix <> (key |> String.replace("-", "_") |> String.upcase()), value}
  end
end
