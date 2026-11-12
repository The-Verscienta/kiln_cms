defmodule KilnCMS.Accounts.Registrations.Erasure do
  @moduledoc """
  Whether rejecting a registration may erase the account (#2514).

  A site with `SiteRegistration.rejected_accounts` set to `:erase_unconfirmed`
  erases a rejected applicant's account (`Changes.EraseRejectedAccount`), but
  only an account that is **nothing but that application**. Erasure cannot be
  undone, and it frees the address, so `check/1` keeps the account unless all
  of these hold:

    * the address was never confirmed. A confirmed rejection is always kept:
      it is what stops the same person registering here again;
    * the registration created the account (`created_account`), so it is not
      somebody's existing account that happened to apply;
    * the account is not already erased, its standing role is `:viewer`, it
      holds no live temporary grant (on the account or on this membership) and
      no audiences;
    * it has no other membership, of any status, on any site;
    * nothing references it: no paid membership, no API key (revoked ones
      included), no content, version, comment, task, media item, release,
      invitation sent, consent recorded, or event it acted in (`blocking/0`).

  Whether the row was still awaiting a decision when it was locked is the
  rejection's own check (`DecideRegistration`), not this one's.

  ## A static list, pinned

  `blocking/0` names every `(table, column)` that may point at an account and
  stops an erasure, and `handled/0` the ones erasure itself scrubs or deletes
  (`Changes.AnonymizeUser`). Written down, not discovered from `pg_constraint`
  at run time: half of them have no foreign key (billing, the history and
  security logs), and a list that changes with the schema would let a new
  table quietly stop blocking. `KilnCMS.Accounts.RegistrationErasureTest`
  holds the two lists to the database instead: every foreign key to `users`
  must be on one of them, and every column on them must exist.

  The one part not written out is content: every compiled content type (and
  the `Entry` tier) gets `author_id` and its versions' `user_id` from
  `KilnCMS.CMS.Content`, so those two columns are read off the registry
  (`ContentTypes.blocks_resources/0`). A project overlay's own types block an
  erasure exactly as pages and posts do, with nothing for the overlay to list.

  ## Under the lock

  `check/1` is one query, run after the account's row is locked
  `FOR UPDATE` (`KilnCMS.Accounts.AccountLock`). Every path that attaches
  something to an account takes the same row first, so what this reads cannot
  change under it, and a confirmation that committed while the erasure waited
  for the lock is seen (READ COMMITTED reads a fresh snapshot per statement).
  """

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Repo

  # Point at an account and stop its erasure. The account is more than an
  # application while any of these has a row for it. Content tables and their
  # versions are added from the registry (`content_blocking/0`).
  @blocking [
    # Accounts and billing
    {"api_keys", "user_id"},
    {"invitations", "invited_by_id"},
    {"billing_memberships", "user_id"},
    {"billing_membership_events", "user_id"},
    {"billing_membership_events", "actor_id"},
    {"newsletter_subscribers", "user_id"},
    {"newsletter_sends", "sent_by_id"},
    # Content history beyond each type's own versions
    {"document_events", "actor_id"},
    {"history_anchors", "actor_id"},
    {"content_consents", "recorded_by_id"},
    {"comments", "author_id"},
    {"comments", "resolved_by_id"},
    {"media_items", "uploaded_by_id"},
    {"content_releases", "creator_id"},
    {"content_releases", "triggered_by_id"},
    {"release_items", "added_by_id"},
    {"tasks", "assignee_id"},
    {"tasks", "completed_by_id"},
    {"tasks", "creator_id"},
    {"site_code_injection_versions", "user_id"},
    # Somebody else's inbox names them as the one who acted
    {"notifications", "actor_id"}
  ]

  # Point at an account and are the erasure's own to scrub or delete
  # (`Changes.AnonymizeUser`), so they do not stop it. `org_memberships` is
  # neither: the rejected row is the application itself, and any other row
  # blocks (`check/1` asks that separately).
  @handled [
    {"notifications", "user_id"},
    {"passkeys", "user_id"},
    {"push_subscriptions", "user_id"},
    {"saved_views", "owner_id"},
    {"user_identities", "user_id"},
    {"security_events", "actor_id"},
    {"security_events", "target_id"},
    {"instance_security_events", "actor_id"},
    {"instance_security_events", "target_id"}
  ]

  @checks [
    confirmed: "u.confirmed_at IS NOT NULL",
    not_created_here: "NOT m.created_account",
    erased: "u.anonymized_at IS NOT NULL",
    not_viewer: "u.role <> 'viewer'",
    live_grant:
      "(u.granted_role IS NOT NULL AND u.granted_role_expires_at > (now() AT TIME ZONE 'utc')) OR " <>
        "(m.granted_role IS NOT NULL AND m.granted_role_expires_at > (now() AT TIME ZONE 'utc'))",
    audiences: "coalesce(cardinality(u.audiences), 0) > 0",
    other_membership:
      "EXISTS (SELECT 1 FROM org_memberships o WHERE o.user_id = u.id AND o.id <> m.id)"
  ]

  @typedoc "Why an account is kept rather than erased."
  @type reason ::
          :confirmed
          | :not_created_here
          | :erased
          | :not_viewer
          | :live_grant
          | :audiences
          | :other_membership
          | {:referenced, String.t()}
          | :not_found

  @doc "Every `{table, column}` whose rows keep an account from being erased."
  @spec blocking() :: [{String.t(), String.t()}]
  def blocking, do: Enum.uniq(@blocking ++ content_blocking())

  # Every content table's `author_id` and its versions table's `user_id`, in
  # registry order. Both columns come from `KilnCMS.CMS.Content`, so every
  # compiled type has them; the registry is fixed at compile time.
  defp content_blocking do
    for {_type, resource} <- ContentTypes.blocks_resources(),
        {table_of, column} <- [
          {resource, "author_id"},
          {Module.concat(resource, Version), "user_id"}
        ] do
      {AshPostgres.DataLayer.Info.table(table_of), column}
    end
  end

  @doc "Every `{table, column}` an erasure scrubs or deletes itself, so it does not block."
  @spec handled() :: [{String.t(), String.t()}]
  def handled, do: @handled

  @doc """
  `:erasable` when the account of `membership` (a registration being rejected)
  is nothing but that application, `{:keep, reason}` otherwise, with the first
  reason found. Must run under the account's `AccountLock.exclusive/1`.
  """
  @spec check(KilnCMS.Accounts.OrgMembership.t()) :: :erasable | {:keep, reason()}
  # sobelow_skip ["SQL.Query"]
  def check(%{id: membership_id, user_id: user_id}) do
    # The statement is built from `@checks` and `blocking/0` (names this
    # module and the compiled registry supply, never input); only the two ids
    # are parameters.
    #
    # Most `@blocking` columns have no index, so this scans those tables while
    # the account's row is locked. It runs only on an admin's rejection that
    # will erase (the site's setting, `erase: true`, a standing admin), never
    # on an ordinary reject; indexing them is a follow-up of its own.
    blocking = blocking()

    case Repo.query!(sql(blocking), [Ecto.UUID.dump!(user_id), Ecto.UUID.dump!(membership_id)]) do
      %{rows: [flags]} -> verdict(reasons(blocking), flags)
      %{rows: []} -> {:keep, :not_found}
    end
  end

  defp reasons(blocking),
    do: Keyword.keys(@checks) ++ Enum.map(blocking, fn {t, c} -> {:referenced, "#{t}.#{c}"} end)

  defp sql(blocking) do
    flags =
      Keyword.values(@checks) ++
        Enum.map(blocking, fn {t, c} ->
          ~s|EXISTS (SELECT 1 FROM "#{t}" x WHERE x."#{c}" = u.id)|
        end)

    """
    SELECT
    #{Enum.map_join(flags, ",\n", &"  (#{&1})")}
    FROM users u
    JOIN org_memberships m ON m.user_id = u.id
    WHERE u.id = $1 AND m.id = $2
    """
  end

  # The first reason whose flag is set, in `reasons/1` order.
  defp verdict(reasons, flags) do
    case Enum.find(Enum.zip(reasons, flags), fn {_reason, set?} -> set? end) do
      nil -> :erasable
      {reason, true} -> {:keep, reason}
    end
  end

  @doc """
  Whether `actor` may erase on `org_id`: a **standing** admin there, the
  platform's or the site's, not one by a temporary grant. A temporary admin
  may reject (the policies admit an effective admin), but the account is kept:
  an erasure outlasts the grant that let them act.
  """
  @spec standing_admin?(map() | nil, Ash.UUID.t()) :: boolean()
  def standing_admin?(%{} = actor, org_id) when is_binary(org_id) do
    # The tier with every grant on the actor's account set aside; a grant on
    # their membership here is set aside by reading that row's own `role`.
    standing = Map.merge(actor, %{granted_role: nil, granted_role_expires_at: nil})

    case Scoping.tier_source(standing, org_id) do
      {:admin, :platform, _user} -> true
      {:admin, :legacy, _user} -> true
      {:admin, :member, membership} -> membership.role == :admin
      _other -> false
    end
  end

  def standing_admin?(_actor, _org_id), do: false
end
