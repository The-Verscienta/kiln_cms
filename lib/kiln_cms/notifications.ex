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

  require Logger

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Accounts.User
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
      define :get_notification, action: :read, get_by: [:id]
      define :mark_notification_read, action: :mark_read
      define :mark_notification_unread, action: :mark_unread
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
      {:ok, count} -> count
      _error -> 0
    end
  end

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
  Mark every unread notification `user` has on `org` as read; returns how many
  moved.

  Streamed rather than atomic because `:mark_read` keeps an already-set
  `read_at` (see the resource) — and because it is authorized per row, so a
  caller cannot sweep an inbox that is not theirs. One user's unread set is
  tens of rows, not thousands.
  """
  @spec mark_all_read(struct(), term()) :: non_neg_integer()
  def mark_all_read(%{id: user_id} = user, org) do
    Notification
    |> Ash.Query.for_read(:unread_for_user, %{user_id: user_id}, actor: user, tenant: org)
    |> Ash.bulk_update(:mark_read, %{},
      actor: user,
      tenant: org,
      strategy: [:stream],
      allow_stream_with: :full_read,
      return_records?: true,
      return_errors?: true
    )
    |> case do
      %Ash.BulkResult{status: :success, records: records} -> length(records || [])
      _partial_or_error -> 0
    end
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

    Enum.each(mentioned, &enqueue_comment(:comment_mention, &1, comment, record, actor))

    comment
    |> thread_audience(record)
    |> reject_actor(actor)
    |> Enum.reject(&MapSet.member?(mentioned_ids, &1.id))
    |> Enum.each(&enqueue_comment(event, &1, comment, record, actor))
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
    participants =
      thread_participants(comment)
      |> Enum.map(& &1.author_id)

    author = record |> Ash.load!(:author, authorize?: false) |> Map.get(:author)

    [author_id(author) | participants]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&user_by_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&wants?(&1, :comment))
  end

  defp thread_participants(comment) do
    KilnCMS.CMS.Comment.thread_comments!(
      comment.content_type,
      comment.content_id,
      comment.block_id,
      authorize?: false,
      tenant: comment.org_id
    )
  end

  defp author_id(%{id: id}), do: id
  defp author_id(_author), do: nil

  defp user_by_id(id) do
    case Ash.get(User, id, authorize?: false) do
      {:ok, user} -> user
      _error -> nil
    end
  end

  defp org_users(record), do: record |> Map.get(:org_id) |> mention_roster()

  @doc """
  The candidates an `@name` in a comment on `org`'s content resolves against:
  this org's members, plus every user who belongs to no org at all — any
  global role — less anyone who has muted comment notifications.

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

  The union is the honest reading of the data: a user with no membership row
  is not scoped to any org, and a user with rows is reachable only from the
  orgs those rows name.

  A system read (`User`'s read policy is self-only). `org` takes the shapes
  `KilnCMS.Accounts.org_id/1` does — nil is the default org. A failed read is
  `[]`: a mention that cannot resolve its candidates simply does not fire.
  """
  @spec mention_roster(struct() | String.t() | nil) :: [struct()]
  def mention_roster(org) do
    org_id = KilnCMS.Accounts.org_id(org)

    members = KilnCMS.Accounts.list_memberships_for_org!(org_id, authorize?: false)
    member_ids = MapSet.new(members, & &1.user_id)
    assigned_ids = assigned_user_ids()

    User
    |> Ash.read!(authorize?: false)
    |> Enum.filter(fn user ->
      (MapSet.member?(member_ids, user.id) or not MapSet.member?(assigned_ids, user.id)) and
        wants?(user, :comment)
    end)
  rescue
    # A mention that cannot resolve its candidate list simply does not fire —
    # the comment is still saved and still visible on the thread.
    _error -> []
  end

  # Every user who is scoped to at least one org.
  #
  # One `MapSet.new/1` call, on a list built by the function below: constructing
  # a MapSet on two branches (the read and its rescue) gives dialyzer two
  # different internal representations for the same opaque type and it rejects
  # the later `member?/2`.
  defp assigned_user_ids, do: MapSet.new(assigned_ids())

  defp assigned_ids do
    KilnCMS.Accounts.OrgMembership
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.user_id)
  rescue
    _error -> []
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

    %{
      "to" => email_of(user),
      "event" => to_string(event),
      "kind" => kind(record),
      "title" => record.title,
      "id" => record.id,
      "actor_name" => actor_name(actor),
      "block_id" => comment.block_id,
      "excerpt" => snippet(comment.body)
    }
    |> then(fn args -> if args["to"], do: enqueue_args(args), else: :ok end)
  end

  defp enqueue_args(args) do
    args |> WorkflowMailWorker.new() |> Oban.insert!()
    :ok
  end

  # A taste of the comment, not the comment. Enough to know whether it needs
  # attention now; short enough that the email is not a copy of a conversation
  # that lives in the editor (and that a private review note is not fanned out
  # in full to everyone's inbox).
  @snippet_max 140
  defp snippet(nil), do: ""

  defp snippet(body) do
    flat = body |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(flat) > @snippet_max,
      do: String.slice(flat, 0, @snippet_max) <> "…",
      else: flat
  end

  # Author-targeted events (`:published`, `:returned_to_draft`) load the author
  # and notify them unless they've muted that event for their account.
  defp notify_author(record, event, actor) do
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
      enqueue(email_of(recipient), event, record, actor)
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
  """
  @spec record_in_app(map()) :: :ok
  def record_in_app(%{user_id: _user_id, org_id: org_id} = attrs) do
    attrs
    |> Map.delete(:org_id)
    |> record_notification!(tenant: org_id)

    # Only after the row exists — see `topic/1` for why the message carries
    # nothing and every subscriber re-reads for itself.
    Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic(attrs.user_id), :notifications_changed)

    :ok
  rescue
    error ->
      Logger.error("in-app notification not recorded: #{Exception.message(error)}")
      :ok
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
      "body" => gettext("A %{kind} is waiting for review.", kind: kind(record)),
      "tag" => "kiln-review",
      "url" => "/editor?status=in_review"
    }

  defp push_payload(:published, record),
    do: %{
      "title" => gettext("Published"),
      "body" => gettext("A %{kind} you authored is now live.", kind: kind(record)),
      "tag" => "kiln-published",
      "url" => "/editor"
    }

  defp push_payload(:returned_to_draft, record),
    do: %{
      "title" => gettext("Changes requested"),
      "body" => gettext("A %{kind} you authored was returned to draft.", kind: kind(record)),
      "tag" => "kiln-returned",
      "url" => "/editor?status=draft"
    }

  # Per-user opt-out (issue #46). Unknown/legacy users default to opted-in.
  defp wants?(%{notify_on_review_request: enabled?}, :submitted_for_review), do: enabled?
  defp wants?(%{notify_on_publish: enabled?}, :published), do: enabled?
  defp wants?(%{notify_on_return_to_draft: enabled?}, :returned_to_draft), do: enabled?
  defp wants?(%{notify_on_comment: enabled?}, :comment), do: enabled?
  defp wants?(_user, _event), do: true

  defp enqueue(nil, _event, _record, _actor), do: :ok

  defp enqueue(to, event, record, actor) do
    %{
      "to" => to,
      "event" => to_string(event),
      "kind" => kind(record),
      "title" => record.title,
      "id" => record.id,
      "actor_name" => actor_name(actor)
    }
    |> WorkflowMailWorker.new()
    |> Oban.insert!()

    :ok
  end

  # Resolve the human-facing content-type name from the registry rather than
  # enumerating each resource: every content type generated via
  # `KilnCMS.CMS.Content` exposes `__kiln_content_type__/0` (the same hook
  # `KilnCMS.CMS.ContentTypes` discovers), so new types (product, recipe, …) work
  # without touching this module. Falls back to "content" for any non-content struct.
  defp kind(%mod{}) do
    if function_exported?(mod, :__kiln_content_type__, 0) do
      to_string(mod.__kiln_content_type__())
    else
      "content"
    end
  end

  # The submitter's display name for the body; nil for actor-less events.
  # Privacy (#214): prefer the user's chosen `name`; never fall back to the
  # email local-part. When no name is set we return nil and the mail worker
  # renders a neutral "An editor" / "A reviewer".
  defp actor_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp actor_name(_actor), do: nil

  defp same_user?(_user, nil), do: false
  defp same_user?(%{id: id}, %{id: id}), do: true
  defp same_user?(_user, _actor), do: false

  # `email` is an `Ash.CiString`, so normalise via `to_string/1`.
  defp email_of(%{email: email}) when not is_nil(email), do: to_string(email)
  defp email_of(_), do: nil
end
