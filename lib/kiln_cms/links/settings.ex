defmodule KilnCMS.Links.Settings do
  @moduledoc """
  The read side of `KilnCMS.CMS.SiteLinkCheck` — whether a site checks its
  outbound links (#474).

  Nothing outside this module reads that resource directly, for the reason the
  resource itself gives: **absence is the default**. A site that has never
  opened the settings page has no row, and `for_org/1` resolving that to `nil`
  while `enabled?/1` resolves it to `false` is what keeps a report page from
  writing a row as a side effect of being looked at.

  ## Deliberately not cached

  `KilnCMS.Branding` and `KilnCMS.CodeInjection` memoize their resolved structs
  because they are read once per anonymous page view. This is read once per
  sweep and once per check — a background job that is about to spend seconds on
  a network round trip. A cache would save nothing measurable and would add an
  invalidation path where "the operator switched egress off and it kept making
  requests" is the failure it produces.

  Reading it in the *worker* rather than only in the sweep is the point: jobs
  enqueued before the switch was flipped are still in the queue after it, and
  the honest place to notice is immediately before the request goes out.
  """

  require Logger

  alias KilnCMS.CMS.SiteLinkCheck

  @doc """
  This site's link-check settings row, or `nil` if it has never been saved.

  Read as `actor`: the link checker's system actor by default (the sweep and
  the check worker), or the person viewing the report, so the system grant
  stays on system code.
  """
  @spec for_org(Ash.UUID.t(), term()) :: SiteLinkCheck.t() | nil
  def for_org(org_id, actor \\ KilnCMS.Links.system()) do
    # `authorize_with: :error` (#1659) so a lost grant is an error here rather
    # than a silently filtered `nil`. Both land on "disabled" below, which is
    # the closed direction for a switch that authorizes outbound requests; the
    # error is also logged.
    case KilnCMS.CMS.list_site_link_check(
           actor: actor,
           authorize_with: :error,
           tenant: org_id,
           query: [limit: 1]
         ) do
      {:ok, rows} ->
        List.first(rows)

      {:error, reason} ->
        # A read failure (or a refused one) must not read as "enabled". The
        # sweep skips the org for this run and says so, which is recoverable;
        # guessing the other way would make a database blip into outbound
        # traffic from a site that never asked for any.
        Logger.warning("link check: could not read settings for #{org_id}: #{inspect(reason)}")
        nil
    end
  end

  @doc "Whether this site checks outbound links. `false` for an absent row."
  @spec enabled?(Ash.UUID.t()) :: boolean()
  def enabled?(org_id) do
    case for_org(org_id) do
      %SiteLinkCheck{external_enabled: enabled?} -> enabled?
      nil -> false
    end
  end

  @doc """
  Turn outbound checking on or off for a site.

  Authorized: this is the one write in the feature a human makes, and the
  resource's policy puts it at org-admin.
  """
  @spec save(Ash.UUID.t(), boolean(), keyword()) :: {:ok, SiteLinkCheck.t()} | {:error, term()}
  def save(org_id, enabled?, opts) do
    KilnCMS.CMS.save_site_link_check(
      %{external_enabled: enabled?},
      Keyword.merge(opts, tenant: org_id)
    )
  end

  @doc """
  Stamp `last_swept_at`, so the report can say when it last had a full answer.

  Silent on failure: the sweep has already done its work and written its rows,
  and failing the job over a timestamp would re-run every check.
  """
  @spec record_sweep(Ash.UUID.t()) :: :ok
  def record_sweep(org_id) do
    case for_org(org_id) do
      nil ->
        :ok

      settings ->
        case KilnCMS.CMS.record_site_link_sweep(settings,
               actor: KilnCMS.Links.system(),
               tenant: org_id
             ) do
          {:ok, _updated} ->
            :ok

          {:error, reason} ->
            Logger.warning("link check: could not stamp sweep for #{org_id}: #{inspect(reason)}")
            :ok
        end
    end
  end

  @doc "Every org that has switched outbound checking on."
  @spec enabled_org_ids() :: [Ash.UUID.t()]
  def enabled_org_ids do
    Enum.filter(KilnCMS.Accounts.list_org_ids(), &enabled?/1)
  end
end
