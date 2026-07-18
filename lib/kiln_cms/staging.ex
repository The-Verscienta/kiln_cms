defmodule KilnCMS.Staging do
  @moduledoc """
  Operator-facing entry point for standing up an **ephemeral staging /
  preview environment** from a production clone. See
  `docs/staging-environments.md`.

  The one public call is `scrub!/1`, which turns a freshly-restored copy of
  production into a PII-free, secret-free environment. It is guarded so a
  mistyped `DATABASE_URL` can't scrub production, then delegates the actual work
  to `KilnCMS.Staging.Scrub`.

  Callable from Mix (`mix kiln.staging.scrub`), from a release before serving
  (`KilnCMS.Release.scrub_staging/0` via `bin/kiln_cms eval`), or against a
  running node (`bin/kiln_cms rpc`).
  """

  alias KilnCMS.Repo
  alias KilnCMS.Staging.Scrub

  # A throwaway database's name must contain one of these, so the scrub can't be
  # aimed at a production database called "kiln_prod" by accident. Override a
  # deliberately-named clone with `force?: true`.
  @ephemeral_markers ~w(staging preview ephemeral tmp scratch)

  @doc """
  Scrub the currently-connected database into a safe staging environment.

  Refuses unless the caller has clearly opted in. Prints the target and a
  summary through `:shell` (default `IO.puts/1`) and returns the summary map.

  ## Options

    * `:confirm?` — must be truthy, or set `KILN_STAGING_SCRUB=confirm`. Without
      it the target is printed and nothing is changed.
    * `:force?` — skip the ephemeral-name check (or `KILN_STAGING_FORCE=1`).
    * `:admin_email` / `:admin_password` — provision one usable admin. Default to
      `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD`.
    * `:shell` — 1-arity logger for human output (default `&IO.puts/1`).
  """
  @spec scrub!(keyword()) :: Scrub.summary()
  def scrub!(opts \\ []) do
    shell = Keyword.get(opts, :shell, &IO.puts/1)
    {host, database} = target()

    confirmed? = Keyword.get(opts, :confirm?) || env_flag?("KILN_STAGING_SCRUB", "confirm")
    forced? = Keyword.get(opts, :force?) || env_flag?("KILN_STAGING_FORCE", "1")

    admin_email = opts[:admin_email] || System.get_env("STAGING_ADMIN_EMAIL")
    admin_password = opts[:admin_password] || System.get_env("STAGING_ADMIN_PASSWORD")

    shell.("Target database: #{database}@#{host}")

    unless confirmed? do
      raise """
      Refusing to scrub without explicit confirmation.

      This deletes personal data and outbound secrets from #{database}@#{host}.
      Confirm you mean this database (NOT production) with `--yes`
      (mix) or `KILN_STAGING_SCRUB=confirm` (release).
      """
    end

    unless forced? or ephemeral_name?(database) do
      raise """
      Refusing to scrub #{inspect(database)}: its name doesn't look ephemeral.

      A staging database name should contain one of: #{Enum.join(@ephemeral_markers, ", ")}.
      If this really is a throwaway clone, re-run with `--force`
      (mix) or `KILN_STAGING_FORCE=1` (release).
      """
    end

    shell.("Scrubbing #{database}@#{host} …")
    summary = Scrub.run(admin_email: admin_email, admin_password: admin_password)
    report(shell, summary)
    summary
  end

  defp report(shell, summary) do
    shell.("""
    Scrub complete:
      users anonymized:        #{summary.users_anonymized}
      API keys purged:         #{summary.api_keys_purged}
      auth tokens purged:      #{summary.tokens_purged}
      webhooks de-activated:   #{summary.webhooks_deactivated}
      mail settings purged:    #{summary.mail_settings_purged}
      search queries purged:   #{summary.search_queries_purged}\
    """)

    case summary.admin_provisioned do
      nil ->
        shell.(
          "  staging admin:           NONE — set STAGING_ADMIN_EMAIL / STAGING_ADMIN_PASSWORD to sign in."
        )

      email ->
        shell.("  staging admin:           #{email} (role :admin, pre-confirmed)")
    end
  end

  # The database name + host the repo is connected to, for the guards and the
  # printed target. Handles both `url:`-style config (prod/staging via
  # DATABASE_URL) and discrete `database:`/`hostname:` config (dev/test).
  defp target do
    config = Repo.config()

    case config[:url] do
      url when is_binary(url) ->
        uri = URI.parse(url)
        {uri.host || "?", String.trim_leading(uri.path || "", "/")}

      _ ->
        {config[:hostname] || "?", to_string(config[:database] || "?")}
    end
  end

  defp ephemeral_name?(database) do
    down = String.downcase(database)
    Enum.any?(@ephemeral_markers, &String.contains?(down, &1))
  end

  defp env_flag?(var, expected) do
    case System.get_env(var) do
      nil -> false
      value -> String.downcase(String.trim(value)) == expected
    end
  end
end
