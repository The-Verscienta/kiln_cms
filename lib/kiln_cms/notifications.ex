defmodule KilnCMS.Notifications do
  @moduledoc """
  Outbound notifications for content-workflow events — email, and Web Push to
  an installed editor PWA (#628).

  Mirrors the webhook pipeline (`KilnCMS.Webhooks`): a lifecycle change calls
  `dispatch/3`, which resolves recipients (as a system read) and enqueues one
  `WorkflowMailWorker` Oban job per recipient. The job builds and delivers the
  Swoosh email, so the editor's request never blocks on mail delivery and a
  transient failure simply retries with backoff.

  Events:

    * `:submitted_for_review` — an editor moved content into review; the admins
      *of the content's org* are notified so someone can approve it: members
      whose tier there is `:admin`, plus platform admins, plus (on the default
      org) membership-less accounts whose global role is `:admin` —
      `KilnCMS.Accounts.Scoping.users_with_tier/2`, the inverse of the
      `effective_tier/2` the approve action itself authorizes against. The
      submitter is skipped if they are themselves one of them.
    * `:published` — content went live; the author is notified. This also covers
      scheduled publishing, where there is no acting user.
    * `:returned_to_draft` — an admin sent reviewed content back to the author.
    * `:comment_added` — someone commented on a block. Everyone already on that
      block's thread hears about it, plus the content's author.
    * `:comment_resolved` — a thread was marked resolved; its participants hear.
    * `:comment_mention` — an `@name` in a comment body resolved to one person
      (`KilnCMS.CMS.Mentions`). Sent *instead of* the thread notification for
      that person, not as well: being named is the stronger signal and two
      emails for one comment is how people mute a feature.
    * `:registration_pending` — someone confirmed their address and waits for
      approval on a site (#2251); that site's admins hear, through
      `KilnCMS.Notifications.Registrations`, which also mails them.

  Each recipient is honoured against their per-user notification preferences
  (`User.notify_on_*`, issue #46) before a job is enqueued: a user who has
  muted an event for their account is skipped. Preferences default on, so
  existing behaviour is unchanged until someone opts out.

  ## Push rides the same recipient decision

  `KilnCMS.Push.notify/2` is called with the *same* filtered recipient list the
  mail jobs are enqueued for, from the one place that computes it. That is the
  point of putting it here rather than at the call sites: a reviewer who muted
  an event must not have it arrive on their phone anyway, and two independent
  recipient rules would drift the first time one of them changed.

  Push is off unless the deployment has VAPID keys, and carries no draft
  content — see `KilnCMS.Push`.

  ## The in-app channel rides it too (#1320)

  So does the third channel: a `KilnCMS.Notifications.Notification` row per
  recipient, which the console bell and `/editor/inbox` read. Same rule, same
  reason — persistence happens in `notify/4` and `enqueue_comment/5`, *after*
  `wants?/2` has already filtered, so an event a user muted for their account
  is absent from their inbox as well as from their mail and their phone. There
  is no second preference lookup and no second recipient list to drift.

  An erased account (`anonymized_at` set) is never a recipient on any
  channel (#2774): `wants?/2` refuses it first, whatever its preferences say,
  and the rosters it would be found on leave it out
  (`KilnCMS.Accounts.Scoping.users_with_tier/2`). The task mail paths that
  do not go through `wants?/2` (`KilnCMS.Notifications.Tasks`,
  `KilnCMS.Notifications.TaskDigestWorker`) skip it themselves.

  Mail takes that decision twice (#3019): once when the job is queued, and
  again when it runs (`mail_recipient/2`), because a mail job can wait hours
  for a retry. The job carries ids only, and the worker reads the recipient,
  their address, the actor's name, the title and the comment back, so an
  account erased or an event muted in the meantime gets nothing, and an actor
  erased in the meantime is "An editor". The second decision only narrows the
  first.

  It re-checks each event's own rule too (#3037, `entitled/3`), through the
  same functions the enqueue used (`KilnCMS.Accounts.Scoping.has_tier?/3`,
  `comment_audience_ids/2`, `mention_roster_member?/2`), so the two sides
  cannot drift: a review request goes only to someone still an admin of the
  site, a published or returned-to-draft notice only to the content's author
  now, a comment notice only to someone still on the thread or the author,
  and a mention only to someone still on the mention roster.

  Best-effort, like the other two: a notification that cannot be written is
  logged and dropped, never raised into the editorial action that caused it.
  The triggering changes (`KilnCMS.CMS.Changes.NotifyWorkflowEmail`,
  `NotifyComment`, `NotifyTaskAssigned`) all run this from
  `Ash.Changeset.after_transaction/2` so the row is inserted after the write
  commits and a rolled-back write notifies nobody.

  Also the Ash domain for that resource — the same shape `KilnCMS.Mail` has,
  where one module is both the channel's entry point and the domain for the
  rows it owns.
  """
  use Ash.Domain
  use Gettext, backend: KilnCMSWeb.Gettext

  require Ash.Query
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.RoleGrant
  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Notifications.Notification
  alias KilnCMS.Notifications.WorkflowMailWorker
  alias KilnCMS.Push

  resources do
    resource Notification do
      # System-only: the notifier writes a row addressed to somebody other
      # than whoever acted, so the action is actor-less by policy rather than
      # by `authorize?: false` — see the resource.
      define :record_notification, action: :notify

      define :notifications_for_user, action: :for_user, args: [:user_id]
      define :unread_notifications_for_user, action: :unread_for_user, args: [:user_id]
      # System-only, like `:notify`: the duplicate check `record_in_app/1`
      # makes before writing a document-level row (#1785).
      define :unread_notification_about,
        action: :unread_about,
        args: [:user_id, :event, :content_id]

      define :get_notification, action: :read, get_by: [:id]
      define :mark_notification_read, action: :mark_read
      define :mark_notification_unread, action: :mark_unread
      # System-only, like `:notify`: a collapsing backup notice that is still
      # unread is told the newest run (#2229).
      define :refresh_notification, action: :refresh
    end
  end

  @doc """
  The PubSub topic one user's notification changes are announced on.

  Deliberately content-free messages (`:notifications_changed`) on a per-user
  topic: a subscriber re-reads under its **own** actor and tenant, so a user
  with two consoles open on two sites cannot be handed the other site's row by
  a broadcast. Re-reading costs two indexed queries; getting the scoping wrong
  costs a cross-tenant leak.
  """
  @spec topic(String.t()) :: String.t()
  def topic(user_id) when is_binary(user_id), do: "notifications:user:#{user_id}"

  @doc """
  The actor the notifier's own reads and bookkeeping run as (#1659): a comment
  thread's participants, and the task digest's reads and its
  "already notified" stamp.

  A `KilnCMS.SystemActor` labelled `:notifications`, admitted by name on
  `CMS.Comment` and `CMS.Task` (see `docs/policy-matrix.md`, "The system
  actor"), rather than `authorize?: false`, which would skip every policy on
  them. Reads of `Accounts.User`, `Accounts.OrgMembership` and content keep
  their bypass, each with its reason at the call site: a standing system grant
  over any of those would be wider than the one recipient list it serves (the
  #1402 argument).
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system, do: KilnCMS.SystemActor.resolve(:notifications)

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process, so a test can take the grant away and prove the migrated reads
  # fail CLOSED (raise) rather than filtering to `[]`, which is how a refused
  # read answers. Process-local, and nothing on a request path calls it; code
  # that could call it could equally pass any actor it liked.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun), do: KilnCMS.SystemActor.with_override(:notifications, actor, fun)

  @doc """
  How many unread notifications `user` has on `org` — the bell's badge and the
  inbox's unread tab.

  Authorized as `user`: the read action filters to their own rows *and* the
  policy requires it, so a wrong `user` argument counts zero rather than
  somebody else's inbox. A failed read counts zero — a badge is chrome, and a
  console page must not 500 because a count query did.
  """
  @spec unread_count(struct(), term()) :: non_neg_integer()
  def unread_count(%{id: user_id} = user, org) do
    Notification
    |> Ash.Query.for_read(:unread_for_user, %{user_id: user_id}, actor: user, tenant: org)
    # A count has no use for the action's `inserted_at: :desc` ordering.
    |> Ash.Query.unset(:sort)
    |> Ash.count(actor: user, tenant: org)
    |> case do
      {:ok, count} ->
        count

      # Zero, deliberately (#1659): this is the reader's own inbox, read under
      # their own actor with no grant that can be lost — a refusal only ever
      # means "not your rows", where zero is the right answer. A failed query
      # still hides nothing: the inbox lists the rows, and this is logged.
      {:error, error} ->
        Logger.warning("unread notification count failed: #{Exception.message(error)}")
        0
    end
  end

  @platform_alert_content_type "platform_security_alert"
  @platform_backups_content_type "platform_backups"

  @doc """
  The `content_type` of a platform security alert's bell row (#2642). The
  rows live in the default org, like every platform alert's; the anchor tells
  them apart from a site alert's (`"security_alert_dispatch"`), so
  `unread_platform_alert_count/2` is one exact filter.
  """
  @spec platform_alert_content_type() :: String.t()
  def platform_alert_content_type, do: @platform_alert_content_type

  @doc """
  The `content_type` of a backup notice's bell row (#2229): a failed or
  partly off-site backup, to every platform admin, in the default org, with
  the default org's id as `content_id`.
  """
  @spec platform_backups_content_type() :: String.t()
  def platform_backups_content_type, do: @platform_backups_content_type

  @doc """
  Every `content_type` a platform-wide bell row carries (#2642, #2229): what
  `unread_platform_alert_count/2` counts.
  """
  @spec platform_alert_content_types() :: [String.t()]
  def platform_alert_content_types,
    do: [@platform_alert_content_type, @platform_backups_content_type]

  @doc """
  How many unread platform alerts `user` has waiting in the default org (the
  security alerts, #2642, and the backup notices, #2229), counted for a console that is **not** the default org's (#2642). Zero
  in the default console, whose bell lists those rows itself, and zero for
  anyone who is not a platform admin right now.

  A number and nothing else, on purpose. Another site's console shows "N
  unread platform alerts" with a link to the default console, and never a
  row's title, excerpt or site name, nor a way to open or mark one there:
  that console is the origin of a site whose own admin may inject script into
  it when no console host is set (threat model residual risk 16, decision
  record 0011), and the alerts are about every site.

  Read as `user`, under the default org, through the same self-only
  `:unread_for_user` read the bell's own count uses. Whether `user` is a
  platform admin is decided in the query, on the account row as it is now
  (`KilnCMS.Accounts.RoleGrant.expression/1`), not on the struct the
  session loaded: an admin demoted mid-session counts zero at the next
  re-read. A failed read counts zero, like `unread_count/2`.
  """
  @spec unread_platform_alert_count(struct(), term()) :: non_neg_integer()
  def unread_platform_alert_count(%{id: user_id} = user, org) do
    default_org_id = Accounts.default_org_id()

    if Accounts.org_id(org) == default_org_id do
      0
    else
      admin = RoleGrant.expression([:admin])

      Notification
      |> Ash.Query.for_read(:unread_for_user, %{user_id: user_id},
        actor: user,
        tenant: default_org_id
      )
      |> Ash.Query.filter(
        content_type in ^platform_alert_content_types() and exists(user, ^admin)
      )
      |> Ash.Query.unset(:sort)
      |> Ash.count(actor: user, tenant: default_org_id)
      |> case do
        {:ok, count} ->
          count

        {:error, error} ->
          Logger.warning("unread platform alert count failed: #{Exception.message(error)}")
          0
      end
    end
  end

  def unread_platform_alert_count(_user, _org), do: 0

  @doc """
  The `limit` most recent notifications for `user` on `org`, newest first —
  the inbox list and the bell's dropdown.

  Read *and* unread: this is "what happened lately", not a queue, and an item
  that vanishes the moment it is read takes its own deep link with it.
  """
  @spec recent(struct(), term(), pos_integer()) :: [Notification.t()]
  def recent(user, org, limit), do: read_window(user, org, :for_user, limit)

  @doc """
  The `limit` most recent **unread** notifications — the inbox's unread filter.

  A separate read rather than a filter over `recent/3`'s window: a backlog
  longer than the window would otherwise hide the oldest unread items behind
  newer read ones, which is the case the filter exists for.
  """
  @spec recent_unread(struct(), term(), pos_integer()) :: [Notification.t()]
  def recent_unread(user, org, limit), do: read_window(user, org, :unread_for_user, limit)

  defp read_window(%{id: user_id} = user, org, action, limit) do
    Notification
    |> Ash.Query.for_read(action, %{user_id: user_id}, actor: user, tenant: org)
    |> Ash.Query.limit(limit)
    |> Ash.read(actor: user, tenant: org)
    |> case do
      {:ok, notifications} -> notifications
      _error -> []
    end
  end

  @doc """
  Mark every unread notification `user` has on `org` as read.

  `{:ok, count}` with how many moved, or `{:error, errors}` when any row
  failed — a caller must not report "Marked 0" for a sweep that broke, which
  is what a bare count made of a failure.

  Streamed rather than atomic because `:mark_read` keeps an already-set
  `read_at` (see the resource) — and because it is authorized per row, so a
  caller cannot sweep an inbox that is not theirs. One user's unread set is
  tens of rows, not thousands.

  Announced **once**, here, rather than per row by
  `KilnCMS.Notifications.Changes.Announce`: every row's announcement would
  send each of the user's open consoles a re-read of its own. Any row that
  did move is enough to announce — a partial sweep still changed the count.
  """
  @spec mark_all_read(struct(), term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def mark_all_read(%{id: user_id} = user, org) do
    result =
      Notification
      |> Ash.Query.for_read(:unread_for_user, %{user_id: user_id}, actor: user, tenant: org)
      |> Ash.bulk_update(:mark_read, %{},
        actor: user,
        tenant: org,
        context: %{announce?: false},
        strategy: [:stream],
        allow_stream_with: :full_read,
        return_records?: true,
        return_errors?: true
      )

    moved = length(result.records || [])

    if moved > 0 do
      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic(user_id), :notifications_changed)
    end

    case result do
      %Ash.BulkResult{status: :success} -> {:ok, moved}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  @doc """
  Mark `user`'s unread `event` notifications about `content_id` on `org` as
  read — what visiting the thing a notification points at does to it (#2251:
  opening the registration queue reads its notice).

  `{:ok, count}` or `{:error, errors}`, like `mark_all_read/2`, and authorized
  the same way: the rows are read as `user` from `user`'s own unread list, and
  each is marked by the recipient-only `:mark_read`, so nobody else's notice
  can be touched. Announced once, when anything moved.
  """
  @spec mark_read_about(struct(), term(), atom(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def mark_read_about(%{id: user_id} = user, org, event, content_id)
      when is_atom(event) and is_binary(content_id) do
    result =
      Notification
      |> Ash.Query.for_read(:unread_for_user, %{user_id: user_id}, actor: user, tenant: org)
      |> Ash.Query.filter(event == ^event and content_id == ^content_id)
      |> Ash.bulk_update(:mark_read, %{},
        actor: user,
        tenant: org,
        context: %{announce?: false},
        strategy: [:stream],
        allow_stream_with: :full_read,
        return_records?: true,
        return_errors?: true
      )

    moved = length(result.records || [])

    if moved > 0 do
      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic(user_id), :notifications_changed)
    end

    case result do
      %Ash.BulkResult{status: :success} -> {:ok, moved}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  @doc """
  Blank `actor_id`'s name on every notification that account caused, on every
  org — the in-app step of erasure (`KilnCMS.Accounts.Changes.AnonymizeUser`).

  The name is a snapshot sitting in *other people's* inboxes (see the
  resource), so scrubbing the account row leaves it behind. The row stays: a
  notification of an event is still a record of the event, and renders the
  neutral "An editor" once the name is gone — the same *what without the who*
  `KilnCMS.History.anonymize_actor/1` keeps for audit events.

  One org at a time, and a failing org does not stop the others; any failure
  raises at the end so the erasure fails loudly and can be retried (the sweep
  is idempotent). The query is not authorized as a read — the read policy is
  self-only, so an actor-less read matches nothing and erasure would silently
  succeed at doing nothing — but the update's own system-only policy still
  runs and decides.
  """
  @spec anonymize_actor(String.t()) :: :ok
  def anonymize_actor(actor_id) when is_binary(actor_id) do
    failed =
      Enum.reject(KilnCMS.Accounts.list_org_ids(), fn org_id ->
        try do
          Notification
          |> Ash.Query.filter(actor_id == ^actor_id)
          |> Ash.bulk_update!(:forget_actor, %{},
            tenant: org_id,
            authorize_query?: false,
            strategy: [:atomic, :atomic_batches, :stream],
            return_records?: false,
            return_errors?: true
          )

          true
        rescue
          error ->
            Logger.error(
              "notification anonymize_actor failed for org #{org_id}: #{inspect(error)}"
            )

            false
        end
      end)

    if failed != [] do
      raise "notification anonymize_actor failed for orgs: #{Enum.join(failed, ", ")}"
    end

    :ok
  end

  @doc """
  Delete every notification addressed to `user_id`, on every org — the
  recipient's side of erasure (`KilnCMS.Accounts.Changes.AnonymizeUser`,
  #2514), where `anonymize_actor/1` is the actor's.

  Same shape and failure handling as `anonymize_actor/1`: one org at a time
  (notifications are tenant-scoped and have no tenant-bypassing action, so a
  delete per site is the cost of an erasure),
  the query not authorized as a read (it is self-only), the destroy's own
  system-only policy deciding, and any failed org raising at the end.
  """
  @spec forget_recipient(String.t()) :: :ok
  def forget_recipient(user_id) when is_binary(user_id),
    do: forget_recipient(user_id, KilnCMS.Accounts.list_org_ids())

  @doc """
  `forget_recipient/1`, over the given orgs only: the erasure backfill
  (`KilnCMS.Accounts.ErasureBackfill`) visits just the orgs where an account
  erased before #2514 still has notifications.
  """
  @spec forget_recipient(String.t(), [Ash.UUID.t()]) :: :ok
  def forget_recipient(user_id, org_ids) when is_binary(user_id) and is_list(org_ids) do
    failed =
      Enum.reject(org_ids, fn org_id ->
        try do
          Notification
          |> Ash.Query.filter(user_id == ^user_id)
          |> Ash.bulk_destroy!(:forget_recipient, %{},
            tenant: org_id,
            authorize_query?: false,
            strategy: [:atomic, :atomic_batches, :stream],
            return_records?: false,
            return_errors?: true
          )

          true
        rescue
          error ->
            Logger.error(
              "notification forget_recipient failed for org #{org_id}: #{inspect(error)}"
            )

            false
        end
      end)

    if failed != [] do
      raise "notification forget_recipient failed for orgs: #{Enum.join(failed, ", ")}"
    end

    :ok
  end

  @type event ::
          :submitted_for_review
          | :published
          | :returned_to_draft
          | :comment_added
          | :comment_resolved

  @spec dispatch(event(), struct(), map() | nil) :: :ok
  def dispatch(:submitted_for_review, record, actor) do
    # The admins OF THE CONTENT'S ORG (#419): the people whose effective tier
    # lets them approve it. Not `User.role == :admin` — on a multi-site install
    # an org's admins are members whose tier comes from their membership, and
    # a global-role query mails platform operators while the site's own
    # approvers never hear about it.
    record
    |> Map.get(:org_id)
    |> Scoping.users_with_tier([:admin])
    |> Enum.reject(&same_user?(&1, actor))
    |> Enum.filter(&wants?(&1, :submitted_for_review))
    |> notify(:submitted_for_review, record, actor)
  end

  def dispatch(:published, record, _actor) do
    notify_author(record, :published, nil)
  end

  def dispatch(:returned_to_draft, record, actor) do
    notify_author(record, :returned_to_draft, actor)
  end

  @doc """
  Notify about an editorial comment (#801).

  `comment` carries the block it is anchored to; `record` is the content it
  lives on, which is what a recipient actually needs a link to.

  Recipients, in one pass so nobody is mailed twice about one comment:

    * anyone `@name`d in the body who resolves unambiguously — as a *mention*,
      which is a different email;
    * everyone else already on that block's thread;
    * the content's author, who owns the thing being discussed.

  The person who wrote the comment is never notified about their own.
  """
  @spec dispatch_comment(:comment_added | :comment_resolved, struct(), struct(), map() | nil) ::
          :ok
  def dispatch_comment(event, comment, record, actor) do
    mentioned = comment |> mentioned_users(record) |> reject_actor(actor)
    mentioned_ids = MapSet.new(mentioned, & &1.id)

    # Every recipient is resolved before anyone is notified: the thread read
    # fails closed (#1659), and a raise mid-fan-out would reach the mentioned
    # and silently skip the thread and the author.
    audience =
      comment
      |> thread_audience(record)
      |> reject_actor(actor)
      |> Enum.reject(&MapSet.member?(mentioned_ids, &1.id))

    Enum.each(mentioned, &enqueue_comment(:comment_mention, &1, comment, record, actor))
    Enum.each(audience, &enqueue_comment(event, &1, comment, record, actor))
  end

  # Never tell someone what they just did — and it is the ACTOR who did it, not
  # the comment's author. Those are the same person when a comment is added and
  # different people when one is resolved, which is exactly the case where
  # excluding the author would have silenced the one person who most needs to
  # know their thread was closed.
  defp reject_actor(users, %{id: actor_id}), do: Enum.reject(users, &(&1.id == actor_id))
  defp reject_actor(users, _actor), do: users

  # A mention only fires on a NEW comment: resolving a thread re-reads a body
  # that was already delivered, and re-notifying everyone it names would turn
  # "resolved" into a second round of pings.
  #
  # `author_id: nil` (#946) means nobody deliberately typed this body — it's
  # an editorial-intelligence finding built from record/duplicate titles and
  # suggestion text (`KilnCMS.Automation.RuleWorker`), none of it sanitized
  # against accidentally containing an `@handle`-shaped substring. Resolving
  # mentions against it anyway would let an unpublished document's own title
  # decide who gets emailed an excerpt of it — a real person never chose to
  # mention anyone, so nobody is (#1252 review). `thread_audience/2` still
  # notifies the thread's normal participants either way.
  defp mentioned_users(%{body: body, author_id: author_id} = comment, record)
       when not is_nil(author_id) do
    if new_comment?(comment) do
      KilnCMS.CMS.Mentions.resolve(body, org_users(record))
    else
      []
    end
  end

  defp mentioned_users(_comment, _record), do: []

  defp new_comment?(%{resolved_at: nil}), do: true
  defp new_comment?(_comment), do: false

  # Everyone with a comment on this block, plus the content's author. Read as
  # the system: a participant's own read policy is about what they may open in
  # the editor, not about whether they are part of a conversation they already
  # joined.
  #
  # `comment.block_id` can be nil (#946): an editorial-intelligence reaction's
  # document-level finding has no single block to be "on", so its thread's
  # other participants are read via `Comment.thread_comments!/4`'s
  # `:for_document` branch instead — `:for_block`'s `block_id` argument is
  # `allow_nil? false` and would raise given nil.
  defp thread_audience(comment, record) do
    comment
    |> comment_audience_ids(Map.get(record, :author_id))
    |> Enum.map(&user_by_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&wants?(&1, :comment))
  end

  @doc """
  The ids of the accounts a comment event on `comment`'s thread is for:
  everyone with a comment on that block's thread, plus `content_author_id`,
  the author of the content it is on (nil for none).

  The one rule for both sides of a comment mail (#3037): `dispatch_comment/4`
  builds its thread audience from it when the comment is written, and
  `KilnCMS.Notifications.WorkflowMailWorker` asks it again when the mail is
  sent, so a recipient is mailed only while they are still on the thread or
  still the author. Preferences and erasure are not part of it: each caller
  takes those from `wants?/2` (through `mail_recipient/2` at send time).

  The thread is read as `system/0` and fails closed: a refused read raises
  rather than answering "nobody".
  """
  @spec comment_audience_ids(struct(), String.t() | nil) :: [String.t()]
  def comment_audience_ids(comment, content_author_id) do
    participants = comment |> thread_participants() |> Enum.map(& &1.author_id)

    [content_author_id | participants]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # As `system/0`, which `CMS.Comment` admits for reads (#1659). Fails CLOSED:
  # a refused read would filter to `[]` and silently drop every participant,
  # so a lost grant raises instead, and `NotifyComment` logs it.
  defp thread_participants(comment) do
    KilnCMS.CMS.Comment.thread_comments!(
      comment.content_type,
      comment.content_id,
      comment.block_id,
      actor: system(),
      authorize_with: :error,
      tenant: comment.org_id
    )
  end

  defp user_by_id(id) do
    # authorize?: false — an `Accounts.User` read (self-only policy): a system
    # grant would cover every account on the deployment, for one by-id lookup.
    case Ash.get(User, id, authorize?: false) do
      {:ok, user} -> user
      _error -> nil
    end
  end

  defp org_users(record), do: record |> Map.get(:org_id) |> mention_roster()

  @doc """
  The candidates an `@name` in a comment on `org`'s content resolves against:
  this org's active members; on the default org only, every account with no
  membership row anywhere, as `KilnCMS.Accounts.Scoping.effective_tier/2`
  reads them; and on every org, every platform admin with no membership row.
  Less anyone who has muted comment notifications or been erased.

  Public because it is the one roster for mentions: `dispatch_comment/4`
  resolves against it after the write, and the content editor's `@`
  autocomplete suggests from it (and seeds a task assignee from it) before.
  Two lists would let the dropdown offer a handle the notifier then cannot
  find, or miss a teammate it would have reached.

  Not simply "the org's members". `OrgMembership` backs the org SWITCHER
  (#336), so a single-org install never materialises a row for anyone —
  scoping strictly to memberships would mean `@name` matched nobody on the
  majority of deployments. And not simply "every user" either: on a
  multi-tenant install that would let a mention carry another tenant's
  content title into an outsider's inbox.

  The membership-less rule is Scoping's legacy rule (#3047): such an account
  holds its global role on the default org and no tier on any other, so it is
  not mentionable there either. That includes a person removed from the only
  site they belonged to, since removal deletes the row. A platform admin is
  `:admin` everywhere, so one with no rows stays on every roster; one who holds
  rows is reachable only from the orgs those rows name.

  A system read (`User`'s read policy is self-only). `org` takes the shapes
  `KilnCMS.Accounts.org_id/1` does — nil is the default org. A failed read is
  `[]`, with a warning logged (`fetch_mention_roster/1`): a mention that cannot
  resolve its candidates simply does not fire.
  """
  @spec mention_roster(struct() | String.t() | nil) :: [struct()]
  def mention_roster(org) do
    case fetch_mention_roster(org) do
      {:ok, users} -> users
      :error -> []
    end
  end

  @doc """
  `mention_roster/1`, saying whether the read worked: `{:ok, users}`, or
  `:error` when the roster could not be read (#3052).

  For a caller that shows the roster to someone, as the content editor's `@`
  autocomplete does: an empty list and a failed read look the same in
  `mention_roster/1`, and only one of them means "nobody to mention". A
  failure logs a warning naming the exception's module only, never its
  message, which may carry account ids or addresses.
  """
  @spec fetch_mention_roster(struct() | String.t() | nil) :: {:ok, [struct()]} | :error
  def fetch_mention_roster(org) do
    org_id = KilnCMS.Accounts.org_id(org)

    # authorize?: false — on this membership read and the user read below: both
    # policies are self-only, and a system grant on either would be a standing
    # read of the deployment's whole account graph — wider than this roster.
    members = KilnCMS.Accounts.list_memberships_for_org!(org_id, authorize?: false)
    member_ids = MapSet.new(members, & &1.user_id)
    assigned_ids = assigned_user_ids()

    # authorize?: false — the user read for the roster: `User` reads are
    # self-only, and a system grant would be a standing read of every account.
    users =
      User
      |> Ash.read!(authorize?: false)
      |> Enum.filter(fn user ->
        on_mention_roster?(
          user,
          org_id,
          MapSet.member?(member_ids, user.id),
          MapSet.member?(assigned_ids, user.id)
        )
      end)

    {:ok, users}
  rescue
    # A mention that cannot resolve its candidate list simply does not fire —
    # the comment is still saved and still visible on the thread. The module
    # only: an Ash error's message can quote the ids or addresses it read.
    error ->
      Logger.warning(
        "mention roster could not be read; mentions on this site resolve to no one " <>
          "(#{inspect(error.__struct__)})"
      )

      :error
  end

  @doc """
  Whether `user` is on `mention_roster(org)` now, decided from that one
  account's membership rows rather than by loading the roster (#3037): the
  mention mail asks it when the job runs, so a person who has since left the
  roster (their membership on the site deactivated or removed, a membership on
  another site added, comment mail muted) is not mailed.

  The same rule as `mention_roster/1`, through the same predicate, so an
  account with no membership rows counts on the default org only (a platform
  admin with none, on every org). `org` nil is the default org, which is what
  a job queued before mention jobs carried an org id resolves to.

  Unlike `mention_roster/1`, a read that fails raises: a caller deciding
  whether to send must not read a failure as either answer.
  """
  @spec mention_roster_member?(struct() | String.t() | nil, User.t()) :: boolean()
  def mention_roster_member?(org, %User{id: user_id} = user) do
    org_id = KilnCMS.Accounts.org_id(org)

    # authorize?: false — this account's membership rows, every status: the
    # policy is self-only, and the roster's own reads above skip it for the
    # same reason. Every row, as `assigned_ids/0` reads them, because any row
    # at all scopes the account.
    rows = KilnCMS.Accounts.list_memberships_for_user!(user_id, authorize?: false)
    member? = Enum.any?(rows, &(&1.organization_id == org_id and &1.status == :active))

    on_mention_roster?(user, org_id, member?, rows != [])
  end

  # The mention roster's rule, for `mention_roster/1` and
  # `mention_roster_member?/2` alike: an active member of the org, or an
  # account with no membership row anywhere, that has not muted comment mail.
  # The membership-less branch is Scoping's legacy rule
  # (`Scoping.effective_tier/2`, `users_with_tier/2`): such an account counts
  # on the default org only, unless it is a platform admin, which is `:admin`
  # on every org.
  defp on_mention_roster?(user, org_id, member?, scoped?) do
    unscoped_here? =
      not scoped? and
        (org_id == Accounts.default_org_id() or Scoping.platform_admin?(user))

    (member? or unscoped_here?) and wants?(user, :comment)
  end

  # Every user who is scoped to at least one org: a membership row on any
  # org, of any status.
  #
  # Raises when the read fails, and `mention_roster/1` turns that into an
  # empty roster. It used to answer an empty set itself, which read as
  # "nobody is scoped to any org" and put every account on every roster
  # (#3037).
  defp assigned_user_ids do
    # authorize?: false — a membership read for the mention roster: its policy
    # is self-only, and a system grant would read the whole account graph.
    KilnCMS.Accounts.OrgMembership
    |> Ash.read!(authorize?: false)
    |> MapSet.new(& &1.user_id)
  end

  # The comment channels, from the one already-filtered audience — the
  # `wants?(&1, :comment)` pass happens in `mention_roster/1` and
  # `thread_audience/2` above, so muting comment mail mutes the inbox too.
  #
  # The in-app row is written for the recipient regardless of whether they
  # have a deliverable address: the preference decision was taken upstream,
  # and `email_of/1` returning nil is a missing *channel*, not an opt-out.
  defp enqueue_comment(event, user, comment, record, actor) do
    persist(user, event, record,
      block_id: comment.block_id,
      excerpt: snippet(comment.body),
      actor: actor
    )

    if email_of(user) do
      record
      |> mail_args(event, user, actor)
      |> Map.merge(%{"block_id" => comment.block_id, "comment_id" => comment.id})
      |> enqueue_args()
    else
      :ok
    end
  end

  defp enqueue_args(args) do
    args |> WorkflowMailWorker.new() |> Oban.insert!()
    :ok
  end

  # A workflow mail job's args: ids only (#3019). The worker reads the
  # recipient, their address and preferences, the actor's name, the title and
  # the comment back when it runs, so a person erased or a preference turned
  # off in the meantime is honoured, and nobody's address, name or words sit
  # in `oban_jobs` (or in Oban's logs and Sentry) while the job waits.
  #
  # No `"to"` and no `"title"`, on purpose: the previous release's worker
  # needs both to build its email, so a job of this shape picked up by an old
  # node during a rolling deploy fails and retries, and a new node delivers
  # it, instead of the old node sending it somewhere wrong. `"kind"` is the
  # content type here and stays.
  defp mail_args(record, event, recipient, actor) do
    %{
      "event" => to_string(event),
      "kind" => kind(record),
      "id" => record.id,
      "user_id" => recipient.id,
      "actor_id" => actor_id(actor),
      # Which site's relay the mail goes out through (#1322).
      "org_id" => Map.get(record, :org_id)
    }
  end

  # A taste of the comment, not the comment. Enough to know whether it needs
  # attention now; short enough that the email is not a copy of a conversation
  # that lives in the editor (and that a private review note is not fanned out
  # in full to everyone's inbox).
  #
  # Public for `WorkflowMailWorker`, which reads the comment back when it runs
  # (#3019) and must quote it exactly as the inbox row does.
  @snippet_max 140
  @doc false
  @spec snippet(String.t() | nil) :: String.t()
  def snippet(nil), do: ""

  def snippet(body) do
    flat = body |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(flat) > @snippet_max,
      do: String.slice(flat, 0, @snippet_max) <> "…",
      else: flat
  end

  # Author-targeted events (`:published`, `:returned_to_draft`) load the author
  # and notify them unless they've muted that event for their account.
  defp notify_author(record, event, actor) do
    # authorize?: false — an `Accounts.User` read (self-only policy): a system
    # grant would cover every account on the deployment, for one name.
    author = record |> Ash.load!(:author, authorize?: false) |> Map.get(:author)

    if author && wants?(author, event) do
      notify([author], event, record, actor)
    else
      :ok
    end
  end

  # One recipient list, every channel. Push first because it is a cheap enqueue
  # that cannot fail the caller; either way the editorial action is already
  # committed and no channel may raise into it.
  #
  # `recipients` has already been through `wants?/2` at every call site above,
  # which is why the in-app row is written here and not at the lifecycle call
  # sites: a muted event is missing from all three channels because there is
  # one decision, taken once. Adding a fourth channel means adding it here.
  defp notify(recipients, event, record, actor) do
    Push.notify(recipients, push_payload(event, record))

    Enum.each(recipients, fn recipient ->
      enqueue(recipient, event, record, actor)
      persist(recipient, event, record, block_id: nil, actor: actor)
    end)
  end

  # The in-app channel for a content record (#1320) — the shape both choke
  # points above hand over.
  defp persist(recipient, event, record, opts) do
    record_in_app(%{
      user_id: recipient.id,
      org_id: Map.get(record, :org_id),
      event: event,
      content_type: kind(record),
      content_id: record.id,
      block_id: Keyword.get(opts, :block_id),
      title: record.title,
      excerpt: Keyword.get(opts, :excerpt),
      actor_id: actor_id(Keyword.get(opts, :actor)),
      actor_name: actor_name(Keyword.get(opts, :actor))
    })
  end

  @doc """
  Record one in-app notification and announce it (#1320).

  Public for `KilnCMS.Notifications.Tasks`, whose recipient is a single known
  assignee resolved next to its own mail rather than through `notify/4`'s
  recipient pass — the same "one decision, every channel" rule, taken in that
  module instead of this one. Everything content-lifecycle-shaped goes through
  `notify/4` / `enqueue_comment/5` and must keep doing so.

  Never raises: a notification that cannot be recorded is logged and dropped,
  because the editorial action it describes has already committed and losing a
  bell badge is a smaller harm than losing the publish.

  The write is **actor-less on purpose** — the row is addressed to `user_id`,
  not to whoever acted, so it cannot be authorized against the acting user.
  The resource's `:notify` policy (`forbid_if actor_present()`) is the grant.
  This is not an `authorize?: false` bypass: the policy runs, and an
  authenticated caller reaching that action is refused by it.

  A document-level lifecycle event (review requested, published, returned to
  draft) that is already waiting **unread** for the same recipient and
  document is not recorded again (#1785) — see the resource's moduledoc.
  `record_in_app_result/1` says which of those happened.
  """
  @spec record_in_app(map()) :: :ok
  def record_in_app(attrs) do
    _outcome = record_in_app_result(attrs)
    :ok
  end

  @doc """
  `record_in_app/1`, saying what became of the row: `:recorded`,
  `:already_waiting` (a collapsing event was still unread, so nothing was
  written), or `:not_recorded` (the write failed, and was logged).

  For a caller whose other channels follow the row — the registration notice
  (`KilnCMS.Notifications.Registrations`) mails an admin only when a new row
  was written, so a second applicant while the first notice is unread is
  neither a second row nor a second email. Never raises.
  """
  @spec record_in_app_result(map()) :: :recorded | :already_waiting | :not_recorded
  def record_in_app_result(%{user_id: _user_id, org_id: _org_id} = attrs) do
    outcome =
      if collapses?(attrs) do
        case record_once(attrs) do
          {:ok, :already_waiting} -> :already_waiting
          {:ok, _notification} -> :recorded
        end
      else
        insert_notification(attrs)
        :recorded
      end

    # Only after the row exists — see `topic/1` for why the message carries
    # nothing and every subscriber re-reads for itself.
    Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic(attrs.user_id), :notifications_changed)

    outcome
  rescue
    error ->
      Logger.error("in-app notification not recorded: #{Exception.message(error)}")
      :not_recorded
  end

  # The events that describe a document's state rather than a message about it
  # (#1785). A second one while the first is still unread tells the recipient
  # nothing new; a second comment, mention or task does. A registration
  # notice is about a site's queue, not one applicant (#2251): a second
  # sign-up while the first notice is unread changes nothing an admin does.
  # A webhook health notice is about one endpoint's state: a second failure
  # streak while the first notice is unread is the same news.
  # A backup notice (#2229) is about the instance's backups, not one run:
  # a second failure while the first is unread is refreshed into the row
  # (`record_in_app_refreshing/1`), not written beside it.
  @collapsing_events [
    :submitted_for_review,
    :published,
    :returned_to_draft,
    :registration_pending,
    :webhook_failing,
    :webhook_disabled,
    :backup_failed,
    :backup_partly_offsite
  ]

  defp collapses?(%{event: event} = attrs),
    do: event in @collapsing_events and is_nil(Map.get(attrs, :block_id))

  defp insert_notification(%{org_id: org_id} = attrs) do
    attrs
    |> Map.delete(:org_id)
    |> record_notification!(tenant: org_id)
  end

  @doc """
  `record_in_app_result/1` for a collapsing event whose row says the newest
  occurrence (#2229, the backup notices): when one is still unread for the
  recipient and anchor, its `title`, `excerpt` and `details` are replaced
  with these (`:refreshed`) instead of being left as they were. Otherwise a
  row is written (`:recorded`). `:not_recorded` when the write failed, which
  is logged. Under the same advisory lock as `record_in_app_result/1`, so two
  writers racing each other leave one row. Never raises.
  """
  @spec record_in_app_refreshing(map()) :: :recorded | :refreshed | :not_recorded
  def record_in_app_refreshing(%{user_id: user_id, org_id: org_id, event: event} = attrs)
      when event in @collapsing_events do
    {:ok, outcome} =
      with_row_lock(attrs, fn ->
        case unread_notification_about(user_id, event, attrs.content_id, tenant: org_id) do
          {:ok, [waiting | _]} ->
            refresh_notification!(waiting, Map.take(attrs, [:title, :excerpt, :details]),
              tenant: org_id
            )

            :refreshed

          _none_or_failed ->
            insert_notification(attrs)
            :recorded
        end
      end)

    Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic(user_id), :notifications_changed)
    outcome
  rescue
    error ->
      Logger.error("in-app notification not recorded: #{Exception.message(error)}")
      :not_recorded
  end

  @doc """
  Mark `user`'s unread `:backup_failed` row read when it is about the run
  `run_id` (#2229): that run was resumed and has now succeeded. A row
  refreshed since to say another run's failure is left unread: that one has
  not recovered. Read and marked as `user`, through their own unread list and
  the recipient-only `:mark_read`, as `mark_read_about/4` does. `{:ok, count}`
  or `{:error, errors}`.
  """
  @spec mark_backup_recovered(struct(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def mark_backup_recovered(%{id: user_id} = user, run_id) when is_binary(run_id) do
    org = Accounts.default_org_id()

    result =
      Notification
      |> Ash.Query.for_read(:unread_for_user, %{user_id: user_id}, actor: user, tenant: org)
      |> Ash.Query.filter(
        event == :backup_failed and content_type == ^@platform_backups_content_type and
          fragment("(?->>'run_id') = ?", details, ^run_id)
      )
      |> Ash.bulk_update(:mark_read, %{},
        actor: user,
        tenant: org,
        context: %{announce?: false},
        strategy: [:stream],
        allow_stream_with: :full_read,
        return_records?: true,
        return_errors?: true
      )

    moved = length(result.records || [])

    if moved > 0 do
      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic(user_id), :notifications_changed)
    end

    case result do
      %Ash.BulkResult{status: :success} -> {:ok, moved}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  @doc """
  Whether a backup report of `class` goes to `user` by email (#2229):
  `class` is `:failed`, `:partial` (reached only some off-site
  destinations), `:succeeded`, `:skipped` or `:canceled`.

  By `User.notify_on_backup`: `:failures` (the default) covers failed and
  partial runs, `:every_run` every class, `:off` none. A value a newer
  release stored (`KilnCMS.Types.UnknownAtom`) counts as `:failures`, the
  default. An erased account gets none. Whether `user` is a platform admin
  is the caller's question, not this one's.
  """
  @spec backup_mail?(map(), :failed | :partial | :succeeded | :skipped | :canceled) ::
          boolean()
  def backup_mail?(%{anonymized_at: %DateTime{}}, _class), do: false

  def backup_mail?(%{notify_on_backup: preference}, class)
      when class in [:failed, :partial, :succeeded, :skipped, :canceled] do
    case preference do
      :every_run -> true
      :off -> false
      _failures_or_unknown -> class in [:failed, :partial]
    end
  end

  def backup_mail?(_user, _class), do: false

  # Check-then-insert, made atomic by a transaction-scoped advisory lock on
  # the row's key: two submits racing each other both check under the lock,
  # so the second sees the first's row. A lock rather than a partial unique
  # index, because the rows this bug already wrote would fail building that
  # index on upgrade, and `notifications` is a large table whose index build
  # would have to run concurrently.
  #
  # A failed check writes the row anyway: a duplicate in the inbox is a
  # smaller harm than a review request nobody hears about.
  defp record_once(%{org_id: org_id, user_id: user_id, event: event} = attrs) do
    with_row_lock(attrs, fn ->
      case unread_notification_about(user_id, event, attrs.content_id, tenant: org_id) do
        {:ok, [_waiting | _]} -> :already_waiting
        _none_or_failed -> insert_notification(attrs)
      end
    end)
  end

  defp with_row_lock(
         %{org_id: org_id, user_id: user_id, event: event, content_id: content_id},
         fun
       ) do
    KilnCMS.Repo.transaction(fn ->
      KilnCMS.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "kiln:notification:#{org_id}:#{user_id}:#{event}:#{content_id}"
      ])

      fun.()
    end)
  end

  # Deliberately content-free beyond the type name — see `KilnCMS.Push`. No
  # title, no excerpt, no id, and the link is the filtered queue rather than
  # the document, so nothing here identifies an unpublished record to the push
  # service or to anyone reading a lock screen over a shoulder.
  # Translated, because a lock screen is the one place a reviewer definitely
  # reads these. `kind/1` is a content-type name, which has no catalog entry —
  # it goes in as an interpolation so the sentence around it can still be
  # translated, which is the best available without a per-type message.
  #
  # A distinct `tag` per event: the service worker coalesces on it, and
  # coalescing two *different* events would silently replace one with the other.
  defp push_payload(:submitted_for_review, record),
    do: %{
      "title" => gettext("Review requested"),
      "body" => gettext("Waiting for review: one %{kind}.", kind: kind(record)),
      "tag" => "kiln-review",
      "url" => "/editor?status=in_review"
    }

  defp push_payload(:published, record),
    do: %{
      "title" => gettext("Published"),
      "body" => gettext("Your %{kind} is now live.", kind: kind(record)),
      "tag" => "kiln-published",
      "url" => "/editor"
    }

  defp push_payload(:returned_to_draft, record),
    do: %{
      "title" => gettext("Changes requested"),
      "body" => gettext("Your %{kind} was returned to draft.", kind: kind(record)),
      "tag" => "kiln-returned",
      "url" => "/editor?status=draft"
    }

  # Per-user opt-out (issue #46). Unknown/legacy users default to opted-in.
  #
  # An erased account wants nothing (#2774). Erasure resets every preference
  # to its default (on), and its address is a tombstone, so without this an
  # author or thread participant erased since would still get an inbox row
  # and a mail job.
  defp wants?(%{anonymized_at: %DateTime{}}, _event), do: false
  defp wants?(%{notify_on_review_request: enabled?}, :submitted_for_review), do: enabled?
  defp wants?(%{notify_on_publish: enabled?}, :published), do: enabled?
  defp wants?(%{notify_on_return_to_draft: enabled?}, :returned_to_draft), do: enabled?
  defp wants?(%{notify_on_comment: enabled?}, :comment), do: enabled?
  defp wants?(_user, _event), do: true

  @doc """
  Whether a queued notification mail may still go to `user` (an account or
  its id) now, when the job runs (#3019): `{:ok, user}` with the account as it
  is now, `{:skip, reason}` when nothing is to be sent, or `{:error, error}`
  when the account could not be read.

  The same decision `dispatch/3` and `dispatch_comment/4` took when the job
  was queued, taken again, because a job can wait hours for a retry: an
  account erased since (#2774) is skipped, whatever its preferences now say,
  and so is one with no address left or one that turned `preference` off
  since (`nil`: no preference governs the mail, as for task mail). It only
  narrows: a recipient the enqueue left out is never added here.
  """
  @spec mail_recipient(User.t() | String.t(), atom() | nil) ::
          {:ok, User.t()} | {:skip, atom()} | {:error, term()}
  def mail_recipient(user_or_id, preference) do
    # The account half is `Accounts.mail_recipient/1`, which account mail
    # (`KilnCMS.Mail.DeliveryWorker`) asks too (#3035); this adds preferences.
    with {:ok, user} <- Accounts.mail_recipient(user_or_id) do
      if is_nil(preference) or wants?(user, preference),
        do: {:ok, user},
        else: {:skip, :muted}
    end
  end

  @doc """
  `mail_recipient/2` for a job queued before #3019, which names its
  recipient by `address` rather than by account: the account holding that
  address now, if it already existed at `queued_at` (the job's
  `inserted_at`), and `{:skip, reason}` otherwise.

  Erasure replaces the address with a tombstone, so an erased recipient has
  no account here. An account registered since with the freed address is
  somebody else, and is skipped. No action changes an account's address once
  it exists (only a create sets it, and erasure replaces it), so the
  account's age is the whole test.
  """
  @spec mail_recipient_by_address(String.t(), DateTime.t() | nil, atom() | nil) ::
          {:ok, User.t()} | {:skip, atom()} | {:error, term()}
  def mail_recipient_by_address(address, queued_at, preference) when is_binary(address) do
    # authorize?: false — an `Accounts.User` read by address (self-only
    # policy), as `KilnCMS.Security.AuthEvents` does: the job already names
    # the address, and the account only decides whether the mail still goes.
    case Accounts.get_user_by_email(address, authorize?: false, not_found_error?: false) do
      {:ok, %User{} = user} ->
        if predates?(user, queued_at),
          do: mail_recipient(user, preference),
          else: {:skip, :address_reassigned}

      {:ok, nil} ->
        {:skip, :no_account}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Whether a queued workflow mail for `event` may still go to `user` (#3037):
  `:ok`, or `{:skip, reason}` when they are no longer who the event is for.

  `mail_recipient/2` asks whether the account may be mailed at all; this asks
  whether it is still entitled to *this* mail. Each event re-checks its own
  rule, the one its enqueue applied, through the same function:

    * `"submitted_for_review"`: still an admin of the site
      (`KilnCMS.Accounts.Scoping.has_tier?/3`, as `users_with_tier/2` chose);
    * `"published"`, `"returned_to_draft"`: still the content's author;
    * `"comment_added"`, `"comment_resolved"`: still on the comment's thread,
      or the content's author (`comment_audience_ids/2`);
    * `"comment_mention"`: still on the site's mention roster
      (`mention_roster_member?/2`), or still on the comment's thread or the
      author (the thread notice a mention replaces).

  `context` carries what the rule needs: `:org_id` (the site), `:author_id`
  (the content's author now) and `:comment` (the comment, as it is now).
  Event names are the job's strings, matched explicitly and never turned into
  atoms. A read that fails raises: it is never read as either answer.
  """
  @spec entitled(String.t(), User.t(), map()) :: :ok | {:skip, atom()}
  def entitled("submitted_for_review", %User{id: user_id}, %{org_id: org_id}) do
    if Scoping.has_tier?(org_id, user_id, [:admin]), do: :ok, else: {:skip, :not_an_admin}
  end

  def entitled(event, %User{id: user_id}, %{author_id: author_id})
      when event in ["published", "returned_to_draft"] do
    if author_id == user_id, do: :ok, else: {:skip, :not_the_author}
  end

  def entitled(event, %User{id: user_id}, %{comment: comment, author_id: author_id})
      when event in ["comment_added", "comment_resolved"] do
    if user_id in comment_audience_ids(comment, author_id),
      do: :ok,
      else: {:skip, :not_on_the_thread}
  end

  # A mention is also a thread notice: `dispatch_comment/4` takes the people
  # it names out of the thread audience, so a participant who was mentioned
  # has only this job. Off the roster but still on the thread or the author,
  # they are still sent it, as the thread notice they would otherwise have
  # had. A legacy job's context has no comment, so only the roster counts.
  def entitled("comment_mention", %User{} = user, %{org_id: org_id} = context) do
    cond do
      mention_roster_member?(org_id, user) -> :ok
      on_the_thread?(user, context) -> :ok
      true -> {:skip, :not_on_the_roster}
    end
  end

  def entitled(_event, _user, _context), do: {:skip, :unknown_event}

  defp on_the_thread?(%User{id: user_id}, %{comment: %{} = comment} = context),
    do: user_id in comment_audience_ids(comment, Map.get(context, :author_id))

  defp on_the_thread?(_user, _context), do: false

  defp predates?(%User{inserted_at: %DateTime{} = created}, %DateTime{} = queued_at),
    do: DateTime.compare(created, queued_at) != :gt

  defp predates?(_user, _queued_at), do: false

  @doc """
  The display name of the account `actor_id` names, as it is now, for a mail
  job's body (#3019): nil, which the mail renders as a neutral "An editor",
  for an account erased since, one with no name, or no account at all.
  Never the address (#214).
  """
  @spec actor_name_now(String.t() | nil) :: String.t() | nil
  def actor_name_now(actor_id) when is_binary(actor_id) do
    # authorize?: false — an `Accounts.User` read (self-only policy), for one
    # display name: the same read the notifier made when it queued the job.
    case Accounts.get_user(actor_id, authorize?: false, not_found_error?: false) do
      {:ok, %User{anonymized_at: nil} = user} -> actor_name(user)
      _no_name -> nil
    end
  end

  def actor_name_now(_actor_id), do: nil

  defp enqueue(recipient, event, record, actor) do
    if email_of(recipient) do
      record
      |> mail_args(event, recipient, actor)
      |> enqueue_args()
    else
      :ok
    end
  end

  # Resolve the human-facing content-type name from the registry rather than
  # enumerating each resource: every content type generated via
  # `KilnCMS.CMS.Content` exposes `__kiln_content_type__/0` (the same hook
  # `KilnCMS.CMS.ContentTypes` discovers), so new types (product, recipe, …) work
  # without touching this module. Falls back to "content" for any non-content struct.
  #
  # A dynamic entry is asked of the registry, by its `type_definition_id`.
  # Every admin-defined type shares `KilnCMS.CMS.Entry`, which exports no
  # `__kiln_content_type__/0` (the entry tier is discovered from rows, not
  # modules), so an entry fell through to "content": the inbox row stored
  # `content_type: "content"`, and the bell, the inbox and the email all
  # linked to `/editor/content/content/:id`, which resolves no type. The
  # registry answers with the type's own name ("recipe") — what the editor
  # route takes, and what `type_name_for/1` exists to give (#927).
  defp kind(%mod{} = record) do
    cond do
      function_exported?(mod, :__kiln_dynamic_entry__, 0) ->
        ContentTypes.type_name_for(record) || "content"

      function_exported?(mod, :__kiln_content_type__, 0) ->
        to_string(mod.__kiln_content_type__())

      true ->
        "content"
    end
  end

  # The submitter's display name for the body; nil for actor-less events.
  # Privacy (#214): prefer the user's chosen `name`; never fall back to the
  # email local-part. When no name is set we return nil and the mail worker
  # renders a neutral "An editor" / "A reviewer".
  defp actor_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp actor_name(_actor), do: nil

  # Only a real account has an id erasure can later find (`anonymize_actor/1`).
  # A system actor (#1402) or no actor at all records nil.
  defp actor_id(%User{id: id}), do: id
  defp actor_id(_actor), do: nil

  defp same_user?(_user, nil), do: false
  defp same_user?(%{id: id}, %{id: id}), do: true
  defp same_user?(_user, _actor), do: false

  # `email` is an `Ash.CiString`, so normalise via `to_string/1`.
  defp email_of(%{email: email}) when not is_nil(email), do: to_string(email)
  defp email_of(_), do: nil
end
