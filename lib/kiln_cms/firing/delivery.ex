defmodule KilnCMS.Firing.Delivery do
  @moduledoc """
  Resilient read path for public artifact delivery — "stays up when the database
  doesn't" (#341).

  Kiln's delivery reads two things: the **published record** for a slug (to get
  the id + last-modified), and the **fired artifact body** for a surface. Both
  are served from in-BEAM caches (`KilnCMS.Cache` for the record,
  `KilnCMS.Firing.Cache` for the body) — Cachex/ETS, no database. This module
  makes that an *explicit, tested guarantee*:

    * Resolution goes **cache-first** through `KilnCMS.Cache.fetch_published/4`
      (already invalidated precisely on content writes), so a warm slug resolves
      with **zero database queries**.
    * The body read is cache-first (`KilnCMS.Firing.Cache` → artifact table).
    * Every database touch is wrapped: if Postgres is unavailable, a warm request
      is unaffected (it never reaches the DB), and a *cold* request degrades
      gracefully to `:unavailable` (a 503) instead of crashing.

  So through a full Postgres outage, delivery keeps answering for any content
  whose record + artifact are warm in cache — a reliability guarantee a
  request-per-query CMS structurally can't match (the BEAM keeps the cache and
  the web layer up independently of the DB connection).
  """
  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Firing
  alias KilnCMS.Firing.Cache

  # Exceptions that mean "the query didn't reach a healthy database": a real
  # production outage (`DBConnection.ConnectionError`) or a downed/absent pool
  # (`DBConnection.OwnershipError`, also what the test sandbox raises for an
  # unallowed process). Deliberately NOT `Postgrex.Error` — that is raised for
  # ordinary SQL failures (bad type, undefined column) which are real defects to
  # surface, not transient outages.
  @db_error_modules [DBConnection.ConnectionError, DBConnection.OwnershipError]

  # Ash re-wraps a DB failure in `Ash.Error.Unknown` and stringifies the
  # underlying exception (e.g. "** (DBConnection.ConnectionError) …"), so the
  # struct type is lost by the time it reaches us — match the *full* connection
  # error names (not a bare "ConnectionError", which could appear in an
  # unrelated error message).
  @db_error_signatures ["DBConnection.ConnectionError", "DBConnection.OwnershipError"]

  @doc """
  Resolve the published record for `{type, slug, locale}`, cache-first.

  Returns `{:ok, record}` (DB-free on a cache hit), `:not_found`, or
  `:unavailable` when the database is down and the record isn't cached.
  """
  @spec published(atom() | String.t(), String.t(), String.t()) ::
          {:ok, struct()} | :not_found | :unavailable
  def published(type, slug, locale) do
    KilnCMS.Cache.fetch_published(to_string(type), slug, locale, fn ->
      ContentTypes.get_published_by_slug(type, slug, locale, authorize?: false)
    end)
    |> case do
      nil -> :not_found
      record -> {:ok, record}
    end
  rescue
    e ->
      cond do
        # A DB outage → serve degraded (503) rather than a misleading 404.
        db_unavailable?(e) ->
          :unavailable

        # A missing slug raises `Ash.Error.Invalid` (NotFound) rather than
        # returning nil — the expected not-found path (→ 404), no log noise.
        match?(%Ash.Error.Invalid{}, e) ->
          :not_found

        # Anything else is an unexpected defect in resolution: still answer 404
        # (behavior-preserving) but log it so it isn't silently swallowed.
        true ->
          Logger.warning(
            "Delivery.published unexpected error for #{type}/#{slug}: #{Exception.message(e)}"
          )

          :not_found
      end
  end

  @doc """
  Read a fired artifact body, cache-first (`Engine.read/3`).

  Returns `{:ok, body}` (DB-free on a cache hit), `:miss` when the artifact
  hasn't been fired yet, or `:unavailable` when the database is down and the
  body isn't cached.
  """
  @spec read_artifact(atom(), Ash.UUID.t(), atom()) :: {:ok, map()} | :miss | :unavailable
  def read_artifact(type, id, surface) do
    # Cache-first, like `Engine.read/3` — but read the artifact table ourselves
    # rather than delegating, because `Engine.read/3` collapses a DB error into
    # the same `:error` it returns for a not-yet-fired artifact. We must tell
    # "not fired" (→ backfill) apart from "database down" (→ serve what's cached,
    # else degrade).
    case Cache.get(type, id, surface) do
      {:ok, body} -> {:ok, body}
      :miss -> fetch_artifact(type, id, surface)
    end
  rescue
    e -> if db_unavailable?(e), do: :unavailable, else: reraise(e, __STACKTRACE__)
  end

  defp fetch_artifact(type, id, surface) do
    case Firing.get_artifact(type, id, surface, authorize?: false) do
      {:ok, %{body: body}} ->
        Cache.put(type, id, surface, body)
        {:ok, body}

      {:error, error} ->
        if db_unavailable?(error), do: :unavailable, else: :miss

      _ ->
        :miss
    end
  end

  @doc """
  Whether an error means the database is unavailable (vs a genuine bug we must
  not swallow). Handles a raw `DBConnection`/`Postgrex` struct, and recurses
  through Ash's wrapping (`%Ash.Error.Unknown{errors: [%{error: "…"}]}`) down to
  the stringified exception message.
  """
  @spec db_unavailable?(term()) :: boolean()
  def db_unavailable?(%mod{}) when mod in @db_error_modules, do: true

  def db_unavailable?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &db_unavailable?/1)

  def db_unavailable?(%{error: error}), do: db_unavailable?(error)

  def db_unavailable?(message) when is_binary(message),
    do: String.contains?(message, @db_error_signatures)

  def db_unavailable?(_), do: false
end
