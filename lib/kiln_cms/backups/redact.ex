defmodule KilnCMS.Backups.Redact do
  @moduledoc """
  The one place backup text is scrubbed of credentials (#2217).

  Everything a backup run writes down for people to read — a `Run`'s error and
  log, an rclone destination's display key, rclone's stderr, values taken from a
  cron manifest — goes through `text/2`. A single path means a new place that
  records text cannot quietly skip one of the passes.

  Three passes, in order of reliability:

    1. **Known secrets**, removed literally (`env`, plus the well-known secret
       variables of this process). Catches a password with characters the
       patterns below cannot match. Secrets shorter than #{6} characters are
       skipped: a short one appears inside ordinary words, and blanking every
       occurrence turns `pg_dump: error` into `***g_dum***: error`.
    2. **URL userinfo** — `scheme://user:pass@host` becomes `scheme://***@host`.
    3. **`key=value` credentials** — `password=…`, `secret_access_key=…`,
       `token=…`, including the rclone connection-string remotes
       (`:s3,access_key_id=…,secret_access_key=…:bucket`, a valid
       `BACKUP_RCLONE_REMOTE`). A quoted value is consumed whole; an unquoted
       one runs to the next whitespace, comma, `&`, `;` or `:`.

  Redaction errs towards removing too much, never too little.
  """

  @min_literal_secret 6

  # Names of variables whose values are secrets whenever they are set.
  @secret_env ~w(PGPASSWORD RCLONE_CONFIG_PASS AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)

  # A key containing one of these words carries a credential.
  @key_words "pass|pwd|secret|token|key|auth|credential|signature"
  @key_value Regex.compile!(
               ~S{(?<![A-Za-z0-9_.-])([A-Za-z0-9_.-]*(?:} <>
                 @key_words <>
                 ~S{)[A-Za-z0-9_.-]*)=(?:'[^']*'|"[^"]*"|[^\s,&;:'"]+)},
               "i"
             )
  @userinfo ~r{([a-z][a-z0-9+.-]*://)[^@\s/]+@}i

  @doc """
  `text` with credentials replaced by `***`.

  `env` is the `[{var, secret}]` list of the environment a command was run
  with. A non-binary `text` is returned as `""`.
  """
  @spec text(term(), [{String.t(), String.t()}]) :: String.t()
  def text(text, env \\ [])

  def text(text, env) when is_binary(text) do
    (env_secrets(env) ++ process_secrets())
    |> Enum.uniq()
    |> Enum.reduce(text, &String.replace(&2, &1, "***"))
    |> String.replace(@userinfo, "\\1***@")
    # `\\1`, NOT `\\g{name}`: `Regex.replace/4` supports numbered groups only,
    # and a named reference makes it raise on exactly the input this scrubs.
    |> String.replace(@key_value, "\\1=***")
  end

  def text(_other, _env), do: ""

  @doc """
  `text/2`, then cut to `max` characters. The cut comes after redaction, so a
  secret straddling the boundary cannot survive as a fragment.
  """
  @spec text(term(), [{String.t(), String.t()}], pos_integer()) :: String.t()
  def text(text, env, max) when is_integer(max) and is_binary(text) do
    # Bound the work first: a cron manifest's text is untrusted and unbounded,
    # and the key=value pattern is quadratic on a long keyword-dense run. The
    # bound is generous (8x the result) so a secret is not cut mid-way in any
    # realistic message; the final cut still comes after redaction.
    text |> String.slice(0, max * 8) |> text(env) |> String.slice(0, max)
  end

  def text(_other, _env, max) when is_integer(max), do: ""

  defp env_secrets(env) do
    for {_var, secret} <- env,
        is_binary(secret),
        String.length(secret) >= @min_literal_secret,
        do: secret
  end

  defp process_secrets do
    for var <- @secret_env,
        secret = System.get_env(var),
        String.length(secret) >= @min_literal_secret,
        do: secret
  end
end
