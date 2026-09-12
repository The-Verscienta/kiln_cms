defmodule KilnCMS.Newsletter.TierSync do
  @moduledoc """
  Keeps tier-backed segments in step with paid memberships (#337 Phase 2).

  Each `KilnCMS.Billing.MembershipTier` gets an auto-maintained
  `KilnCMS.Newsletter.Segment` (`managed_by: :tier`). This module is what puts
  people in and out of it.

  ## Consent and entitlement are separate bits

  This module writes **only** the join rows and the `user_id` link. It never
  touches `Subscriber.status`.

  That separation is the whole "opt out of email without cancelling your paid
  subscription" requirement:

    * `Subscriber.status` is **consent** — the person's own choice, changed only
      by them (confirm / unsubscribe / `/account`);
    * `Billing.Membership.status` is **entitlement** — what they paid for;
    * segment membership is just "which list are you on".

  Because `read :confirmed` filters on `status == :confirmed` **and** segment
  membership, an unsubscribed member sits in the tier segment and receives
  nothing, while keeping full content access. Cancelling a subscription removes
  the join row and leaves their consent record and any hand-built segment
  memberships untouched.

  A brand-new subscriber lands `:pending` — see
  `KilnCMS.Newsletter.Subscriber.link_member`.

  ## Called from two places

  Event-driven from the membership transition (so it can't drift from the
  entitlement recompute), and from a nightly reconcile as the net, since provider
  webhooks are at-least-once *and* occasionally missed.

  ## How this sync is authorized (#1309, #1402)

  There is no acting user in hand: the callers are `Billing.Changes.RecordTransition`
  (a membership transition's `after_action`, where `user_id` / `org_id` come
  from the `Billing.Membership` row) and `Billing.MembershipTier`'s
  `after_action` (an org admin's tier create/update, whose `name` / `slug` /
  `description` feed `ensure_segment/1` — request-authored, but under a policy
  that admitted only an `OrgAdmin` of that org).

  So it runs as `%KilnCMS.SystemActor{subsystem: :newsletter}`, and every
  resource it touches admits that actor by name rather than being bypassed:
  `Newsletter.Segment` for `:read` / `:for_tier` / `:sync_managed`,
  `Newsletter.Subscriber` for `:read` / `:link_member`,
  `Newsletter.SegmentMembership` outright (the sync is what maintains those
  join rows), and `Billing.Membership` for reads. The two tier-backed actions
  are `forbid_if always()` for every person, admin included — they always were,
  and now the one caller that may take them says so in the policy block.

  Every Newsletter read/write below carries `tenant: org_id`, so nothing
  crosses a site. Two reads are tenant-less by design:
  `Billing.memberships_for_export` is a `multitenancy :bypass` cross-org read
  that `entitled_tiers/2` filters back down to `org_id` in memory, and
  `Accounts.get_user` reads the global `User` table by the membership's own id
  — that one keeps `authorize?: false`, deliberately, because `User`'s read
  policy is self-only and a system clause there would be a standing grant over
  every account on the deployment.
  """
  require Ash.Query
  require Logger

  alias KilnCMS.Billing
  alias KilnCMS.Newsletter

  # See "How this sync is authorized" above.
  defp system_actor, do: KilnCMS.SystemActor.new(:newsletter)

  @doc """
  Reconcile one person's tier-segment membership within one organization.

  Returns `:ok` regardless: a newsletter bookkeeping failure must never roll back
  the entitlement transaction that triggered it — access is the thing that
  matters, and the nightly reconcile will pick this up.
  """
  @spec sync_user(Ash.UUID.t(), Ash.UUID.t()) :: :ok
  def sync_user(user_id, org_id) do
    with {:ok, entitled_tier_ids} <- entitled_tiers(user_id, org_id),
         {:ok, segments} <- managed_segments(org_id) do
      apply_sync(user_id, org_id, entitled_tier_ids, segments)
    else
      {:error, reason} ->
        Logger.warning("newsletter tier sync failed for #{user_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("newsletter tier sync crashed for #{user_id}: #{inspect(error)}")
      :ok
  end

  @doc """
  Ensure a tier has its auto-maintained segment, creating it if missing.

  Called when a tier is created or reactivated, so the segment always exists
  before a membership on it activates — no admin step to forget.
  """
  @spec ensure_segment(struct()) :: :ok
  def ensure_segment(tier) do
    Newsletter.create_tier_segment(
      tier.id,
      tier.audience,
      %{
        name: tier.name,
        slug: "tier-" <> tier.slug,
        description: tier.description
      },
      # `:for_tier` is `forbid_if always()` — closed to every person, admin
      # included — and admits this sync's system actor by name (#1402).
      actor: system_actor(),
      tenant: tier.org_id
    )

    :ok
  rescue
    error ->
      Logger.warning("could not ensure tier segment for #{tier.id}: #{inspect(error)}")
      :ok
  end

  # Tenant-less on purpose: `:all_for_user` is `multitenancy :bypass`; the read
  # is narrowed to `org_id` right below (moduledoc). `Billing.Membership`
  # admits this actor for reads (#1402) — a paid membership is exactly what
  # grants the tier segment being synced.
  defp entitled_tiers(user_id, org_id) do
    case Billing.memberships_for_export(user_id, actor: system_actor()) do
      {:ok, memberships} ->
        ids =
          memberships
          |> Enum.filter(&(&1.org_id == org_id and Billing.Membership.entitling?(&1.status)))
          |> MapSet.new(& &1.tier_id)

        {:ok, ids}

      error ->
        error
    end
  end

  defp managed_segments(org_id) do
    KilnCMS.Newsletter.Segment
    # System read, tenant-scoped — `Segment` admits this actor for `:read`,
    # `:for_tier` and `:sync_managed`, and nothing else (#1402).
    |> Ash.Query.for_read(:read, %{}, actor: system_actor(), tenant: org_id)
    |> Ash.Query.filter(managed_by == :tier)
    |> Ash.read()
  end

  defp apply_sync(user_id, org_id, entitled_tier_ids, segments) do
    wanted = Enum.filter(segments, &MapSet.member?(entitled_tier_ids, &1.tier_id))
    unwanted = Enum.reject(segments, &MapSet.member?(entitled_tier_ids, &1.tier_id))

    subscriber = subscriber_for(user_id, org_id, wanted != [])

    if subscriber do
      Enum.each(wanted, &join(subscriber, &1, org_id))
      Enum.each(unwanted, &leave(subscriber, &1, org_id))
    end

    :ok
  end

  # Find (or, only when they're entitled to something, create) the subscriber row.
  # A member who holds nothing here gets no row conjured for them.
  defp subscriber_for(user_id, org_id, create?) do
    existing =
      KilnCMS.Newsletter.Subscriber
      # System read, tenant-scoped — `Subscriber` admits this actor for `:read`
      # and `:link_member`, and nothing else (#1402).
      |> Ash.Query.for_read(:read, %{}, actor: system_actor(), tenant: org_id)
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.Query.limit(1)
      |> Ash.read!()
      |> List.first()

    cond do
      existing -> existing
      not create? -> nil
      true -> link_new(user_id, org_id)
    end
  end

  # Upserts on email, so an existing hand-added subscriber is LINKED rather than
  # duplicated — and `upsert_fields [:user_id]` means their consent status is
  # untouched by the link.
  #
  # `get_user` keeps its bypass deliberately (#1402): `User`'s read policy is
  # self-only, so admitting the system actor there would be a standing grant
  # over every account on the deployment — far wider than this by-primary-key
  # read of the one row the membership itself names, of which only the email
  # and name are used. `link_member` is `forbid_if always()` for every person
  # and admits this actor by name.
  defp link_new(user_id, org_id) do
    with {:ok, user} <- KilnCMS.Accounts.get_user(user_id, authorize?: false),
         true <- verified?(user),
         {:ok, subscriber} <-
           Newsletter.link_member_subscriber(
             user.id,
             %{email: to_string(user.email), name: user.name},
             # `link_member` is `forbid_if always()` for every person (see
             # above) and admits this actor by name.
             actor: system_actor(),
             tenant: org_id
           ) do
      subscriber
    else
      _other -> nil
    end
  end

  # Only a confirmed address is ever added to a mailing list. The password
  # strategy does not require confirmation to sign in, so this is checked here
  # rather than assumed — adding an unverified address would let someone sign up
  # with a stranger's email and subscribe them to mail.
  defp verified?(%{confirmed_at: nil}), do: false
  defp verified?(_user), do: true

  # Checks for the existing row rather than inserting and catching the unique
  # violation. This runs inside the membership transition's TRANSACTION, and a
  # failed INSERT aborts the enclosing Postgres transaction — so letting the
  # constraint fire would take the entitlement write down with it on every
  # re-sync of an already-synced member.
  defp join(subscriber, segment, org_id) do
    if joined?(subscriber, segment, org_id) do
      :ok
    else
      Newsletter.add_to_segment(
        %{segment_id: segment.id, subscriber_id: subscriber.id},
        # `SegmentMembership` admits this actor (#1402): the sync is what adds
        # and removes the tier-backed join rows as entitlements change.
        actor: system_actor(),
        tenant: org_id
      )
    end
  end

  # The other half of `join/3`'s grant on `SegmentMembership` (#1402).
  defp leave(subscriber, segment, org_id) do
    subscriber
    |> join_rows(segment, org_id)
    |> Enum.each(&Newsletter.remove_from_segment(&1, actor: system_actor(), tenant: org_id))
  end

  defp joined?(subscriber, segment, org_id),
    do: join_rows(subscriber, segment, org_id) != []

  defp join_rows(subscriber, segment, org_id) do
    KilnCMS.Newsletter.SegmentMembership
    # System read, tenant-scoped — same grant as `join/3` (#1402).
    |> Ash.Query.for_read(:read, %{}, actor: system_actor(), tenant: org_id)
    |> Ash.Query.filter(segment_id == ^segment.id and subscriber_id == ^subscriber.id)
    |> Ash.read!()
  end
end
