defmodule KilnCMS.Demo.Guard do
  @moduledoc """
  The refusals that stand between `KilnCMS.Demo.reset/1` and a database it must
  never touch. See `docs/demo-mode.md`.

  A demo reset drops every table in the database it is pointed at, on a timer,
  with nobody watching. So it has to be *unable* to run anywhere else, not
  merely configured not to — and every check here is independent, because the
  accident this exists to prevent is one setting being wrong while the others
  look fine:

    * **Enabled with a sentinel.** `KILN_DEMO_RESET=confirm`, where `true`
      deliberately does not count (the `KILN_STAGING_SCRUB` convention).
    * **The database is named like a demo.** Its name must contain `demo`. There
      is no `--force`: a demo database is created fresh for the purpose, so the
      operator chooses its name, and the one deployment that must never match is
      the one nobody named that way.
    * **The site is served like a demo.** The endpoint host (`PHX_HOST`) must
      contain `demo`, or be `localhost` for a developer trying this locally. A
      production node pointed at a demo database by a copy-pasted
      `DATABASE_URL` still refuses.
    * **The URL the tools would use is the database the app is using.**
      `pg_restore`/`psql` connect by URL (`KilnCMS.Backups.database_url/0`),
      which `BACKUP_DATABASE_URL` can point somewhere else entirely. Checking the
      Repo's name and then restoring into a different database would make every
      check above decorative.
    * **The golden snapshot came from a demo.** Its archive header names the
      database it was dumped from. Restoring a *production* backup into a public
      demo would publish production's accounts — password hashes included — to
      anyone who opens the sign-in page.

  Pure functions over a plain map, so each refusal is tested with exact values
  rather than by staging a database for it.
  """

  @marker "demo"

  @type target :: %{
          enabled?: boolean(),
          repo_host: String.t(),
          repo_database: String.t(),
          url: String.t() | nil,
          site_host: String.t() | nil
        }

  @type reason ::
          :disabled
          | {:database_not_demo, String.t()}
          | {:host_not_demo, String.t() | nil}
          | :no_database_url
          | {:url_mismatch, {String.t() | nil, String.t()}, {String.t(), String.t()}}
          | {:golden_not_demo, String.t() | nil}

  @doc """
  `:ok` when `target` may be reset, else the first refusal.

  Ordered so the message an operator reads is the most fundamental one: a
  deployment that never enabled demo mode hears that, not a complaint about its
  database name.
  """
  @spec check(target()) :: :ok | {:error, reason()}
  def check(%{} = target) do
    cond do
      target.enabled? != true ->
        {:error, :disabled}

      not demo_name?(target.repo_database) ->
        {:error, {:database_not_demo, target.repo_database}}

      not demo_host?(target.site_host) ->
        {:error, {:host_not_demo, target.site_host}}

      is_nil(target.url) ->
        {:error, :no_database_url}

      url_target(target.url) != {target.repo_host, target.repo_database} ->
        {:error,
         {:url_mismatch, url_target(target.url), {target.repo_host, target.repo_database}}}

      true ->
        :ok
    end
  end

  @doc """
  `:ok` when the golden archive was dumped from a database named like a demo.

  `nil` — an archive whose header names no database — is refused too: "we
  couldn't tell where this came from" is not a reason to publish it.
  """
  @spec check_golden_source(String.t() | nil) :: :ok | {:error, reason()}
  def check_golden_source(source_database) do
    if demo_name?(source_database),
      do: :ok,
      else: {:error, {:golden_not_demo, source_database}}
  end

  @doc "Whether a database name marks it as a demo (case-insensitive `demo`)."
  @spec demo_name?(String.t() | nil) :: boolean()
  def demo_name?(name) when is_binary(name),
    do: name |> String.downcase() |> String.contains?(@marker)

  def demo_name?(_name), do: false

  @doc """
  Whether a served host marks the deployment as a demo.

  `localhost` passes so the feature can be tried on a laptop. Production cannot
  reach it by default: `runtime.exs` falls back to `example.com` when
  `PHX_HOST` is unset, not to `localhost`.
  """
  @spec demo_host?(String.t() | nil) :: boolean()
  def demo_host?("localhost"), do: true
  def demo_host?(host) when is_binary(host), do: demo_name?(host)
  def demo_host?(_host), do: false

  # `{host, database}` of a connection URL, in the same shape `Repo.target/0`
  # returns, so the two compare directly.
  defp url_target(url) do
    uri = URI.parse(url)
    {uri.host, String.trim_leading(uri.path || "", "/")}
  end
end
