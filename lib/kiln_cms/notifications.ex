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

    * `:submitted_for_review` — an editor moved content into review; every admin
      (except the submitter, if they are themselves an admin) is notified so
      someone can approve it.
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
  """
  require Ash.Query

  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Accounts.User
  alias KilnCMS.Notifications.WorkflowMailWorker
  alias KilnCMS.Push

  @type event ::
          :submitted_for_review
          | :published
          | :returned_to_draft
          | :comment_added
          | :comment_resolved

  @spec dispatch(event(), struct(), map() | nil) :: :ok
  def dispatch(:submitted_for_review, record, actor) do
    User
    |> Ash.Query.filter(role == :admin)
    |> Ash.read!(authorize?: false)
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
  defp mentioned_users(%{body: body} = comment, record) do
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
  # other participants are read via `list_comments_for_document!` instead —
  # `:for_block`'s `block_id` argument is `allow_nil? false` and would raise
  # given nil, the same split `KilnCMS.CMS.Changes.RouteToBlockThread` makes.
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

  defp thread_participants(%{block_id: nil} = comment) do
    KilnCMS.CMS.list_comments_for_document!(
      comment.content_type,
      comment.content_id,
      authorize?: false,
      tenant: comment.org_id
    )
  end

  defp thread_participants(comment) do
    KilnCMS.CMS.list_comments_for_block!(
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

  # Candidates for an `@name`: this org's members, plus every user who belongs
  # to no org at all.
  #
  # Not simply "the org's members". `OrgMembership` backs the org SWITCHER
  # (#336), so a single-org install never materialises a row for anyone —
  # scoping strictly to memberships would mean `@name` matched nobody on the
  # majority of deployments. And not simply "every user" either: on a
  # multi-tenant install that would let a mention carry another tenant's
  # content title into an outsider's inbox.
  #
  # The union is the honest reading of the data: a user with no membership row
  # is not scoped to any org, and a user with rows is reachable only from the
  # orgs those rows name.
  defp org_users(record) do
    org_id = Map.get(record, :org_id) || KilnCMS.Accounts.default_org_id()

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

  defp enqueue_comment(event, user, comment, record, actor) do
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

  # One recipient list, both channels. Push first because it is a cheap enqueue
  # that cannot fail the caller; either way the editorial action is already
  # committed and neither channel may raise into it.
  defp notify(recipients, event, record, actor) do
    Push.notify(recipients, push_payload(event, record))
    Enum.each(recipients, &enqueue(email_of(&1), event, record, actor))
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
  # `KilnCMS.CMS.ContentTypes` discovers), so new types (herb, formula, …) work
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
