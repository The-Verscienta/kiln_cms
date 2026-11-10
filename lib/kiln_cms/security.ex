defmodule KilnCMS.Security do
  @moduledoc """
  The security audit log domain (#2241): an append-only, org-scoped record of
  security-sensitive events (sign-ins and lockouts, second factors, passkeys,
  role and elevation grants, API keys, SSO and org-setting changes).

  Reading is an org-admin act. Writing is not a person's act at all: events are
  recorded, anonymized and pruned as `system/0`, a `KilnCMS.SystemActor`
  labelled `:security`, admitted by action name on `KilnCMS.Security.Event`
  (see `docs/policy-matrix.md`, "The system actor"). No person, admin
  included, can create, edit or delete an event.

  It also holds `KilnCMS.Security.PostureReport` (#2252): the Security
  posture page's action and monitoring's detail-free snapshot of it (#2521),
  which read settings and store nothing.

  `KilnCMS.Security.IpBlocklist` and `KilnCMS.Security.Cidr` live in the same
  namespace but are unrelated to this domain.

  ## Erasure and retention fail closed

  `anonymize_actor/1` and `prune/1` run as bulk operations whose queries are
  authorized as filters by default, so a lost grant would match nothing and
  report success: an erasure that erased nothing, a retention that kept
  everything. Both pass `authorize_query_with: :error` (and read their chunks
  with `authorize_with: :error`), turning that into a raise.
  """
  use Ash.Domain

  require Ash.Query

  alias KilnCMS.Security.Event

  resources do
    resource Event do
      # The admin console reads `list`; everything that writes is the
      # `:security` system actor's.
      define :record, action: :record
      define :list_events, action: :list
      define :events_by_actor, action: :by_actor, args: [:user_id]
      define :events_older_than, action: :older_than, args: [:cutoff]
      define :sign_in_events_from_ip, action: :sign_in_from_ip, args: [:ip, :since]
      define :get_event, action: :read, get_by: [:id]
    end

    # The Security posture page (#2252), and its detail-free snapshot for
    # `GET /api/security/posture` (#2521, cached 30 s per site and scope set).
    resource KilnCMS.Security.PostureReport do
      define :run_posture, action: :run
      define :posture_snapshot, action: :snapshot
    end
  end

  @doc """
  The actor the audit log is written as: a `KilnCMS.SystemActor` labelled
  `:security`. Honours `with_actor/2`.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system, do: KilnCMS.SystemActor.resolve(:security)

  @doc false
  # Test seam: run `fun` with `system/0` answering `actor`, so a test can take
  # the grant away and prove erasure and pruning fail CLOSED.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun), do: KilnCMS.SystemActor.with_override(:security, actor, fun)

  @doc """
  Scrub every event a now-erased user is the actor or the target of, across all
  orgs, retaining the events themselves (GDPR erasure, #2241). Runs as
  `system/0`.

  Per event: `actor_id` / `target_id` naming the user are nilled, and for an
  event the user acted in `actor_label`, `ip` and `user_agent` are cleared too.
  `metadata` is emptied on every touched event. Idempotent.

  **Fails closed**, and per org: one org's failure is logged and the sweep
  continues, then raises at the end so the caller retries (a partial erasure is
  a compliance gap). Same shape as `KilnCMS.History.anonymize_actor/1`.
  """
  @spec anonymize_actor(Ecto.UUID.t()) :: :ok
  def anonymize_actor(user_id) when is_binary(user_id) do
    failures =
      Enum.reduce(KilnCMS.Accounts.list_org_ids(), [], fn org_id, failed ->
        try do
          Event
          |> Ash.Query.for_read(:by_actor, %{user_id: user_id},
            actor: system(),
            tenant: org_id
          )
          |> Ash.bulk_update!(:anonymize_actor, %{user_id: user_id},
            actor: system(),
            authorize_query_with: :error,
            authorize_changeset_with: :error,
            tenant: org_id,
            strategy: :stream,
            return_records?: false,
            return_errors?: true
          )

          failed
        rescue
          error ->
            require Logger
            Logger.error("security anonymize_actor failed for org #{org_id}: #{inspect(error)}")
            [org_id | failed]
        end
      end)

    unless failures == [] do
      raise "security anonymize_actor incomplete for orgs #{inspect(failures)} — retry the erasure"
    end

    :ok
  end

  @doc """
  The retention window, in days, for an org's security log (#2241): its
  `KilnCMS.CMS.SiteSecurityLog` row, else #{KilnCMS.CMS.SiteSecurityLog.default_days()}.
  `0` means keep forever.

  `org` is an org id, an `Organization` or `nil` (the default org). Read as
  `KilnCMS.OrgSettings.system(:security)` with `authorize_with: :error`, and
  **fails closed to "keep"**: an unreadable row returns `0`, so a pruner never
  deletes on a window it could not confirm. Not cached; the prune worker reads
  it once per org per day.
  """
  @spec retention_days(KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          non_neg_integer()
  def retention_days(org) do
    actor = KilnCMS.OrgSettings.system(:security)

    resolved =
      KilnCMS.OrgSettings.resolve_uncached(KilnCMS.Accounts.org_id(org),
        read:
          &KilnCMS.CMS.list_site_security_log(
            tenant: &1,
            actor: actor,
            authorize_with: :error
          ),
        # `nil` is reserved for "could not read", so "no row" is its own value.
        build: fn
          nil -> KilnCMS.CMS.SiteSecurityLog.default_days()
          row -> row.security_log_retention_days
        end,
        label: "security log retention"
      )

    resolved || 0
  end

  @doc """
  Set an org's retention window (admin only). `days` is a whole number from
  `0` (keep forever) to #{KilnCMS.CMS.SiteSecurityLog.max_days()}; anything
  else is an `{:error, %Ash.Error.Invalid{}}`. Pass `actor:` (an org admin;
  editors, viewers and anonymous callers are refused) and `tenant:` as for any
  Ash call.
  """
  @spec set_retention_days(non_neg_integer(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def set_retention_days(days, opts) do
    KilnCMS.CMS.save_site_security_log(%{security_log_retention_days: days}, opts)
  end

  @default_chunk 500

  @doc """
  Delete events past their retention window (#2241). Runs as `system/0`.

  Options:

    * `:org_id` - prune one org (default: every org).
    * `:retention_days` - delete events older than this many days. `0` (or
      `nil`) means keep forever and deletes nothing.
    * `:older_than` - an explicit `DateTime` cutoff instead of `:retention_days`.
    * `:chunk_size` - rows per delete (default #{@default_chunk}).

  Deletes in keyset-ordered chunks (by `id`, resuming after the last chunk's
  last id) so a large backlog is never one transaction and a chunk that cannot
  be deleted cannot spin the loop. Returns `{:ok, deleted_count}`. **Fails
  closed**: a lost grant or a failed delete raises.
  """
  @spec prune(keyword()) :: {:ok, non_neg_integer()}
  def prune(opts \\ []) do
    case cutoff(opts) do
      nil ->
        {:ok, 0}

      cutoff ->
        org_ids = if org_id = opts[:org_id], do: [org_id], else: KilnCMS.Accounts.list_org_ids()
        chunk = Keyword.get(opts, :chunk_size, @default_chunk)
        {:ok, Enum.reduce(org_ids, 0, &(&2 + prune_org(&1, cutoff, chunk, nil, 0)))}
    end
  end

  defp cutoff(opts) do
    cond do
      at = opts[:older_than] ->
        at

      days = opts[:retention_days] ->
        if days > 0, do: DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

      true ->
        nil
    end
  end

  defp prune_org(org_id, cutoff, chunk, after_id, deleted) do
    page =
      Event
      |> Ash.Query.for_read(:older_than, %{cutoff: cutoff}, actor: system(), tenant: org_id)
      |> then(&if after_id, do: Ash.Query.filter(&1, id > ^after_id), else: &1)
      |> Ash.Query.sort([id: :asc], prepend?: true)
      |> Ash.Query.limit(chunk)
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize_with: :error)

    case page do
      [] ->
        deleted

      page ->
        Ash.bulk_destroy!(page, :prune, %{},
          actor: system(),
          authorize_changeset_with: :error,
          tenant: org_id,
          strategy: :stream,
          return_errors?: true
        )

        prune_org(org_id, cutoff, chunk, List.last(page).id, deleted + length(page))
    end
  end
end
