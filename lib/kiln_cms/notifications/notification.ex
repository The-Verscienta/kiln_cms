defmodule KilnCMS.Notifications.Notification do
  @moduledoc """
  One persisted in-app notification — the third channel of
  `KilnCMS.Notifications` (#1320), alongside the email and the Web Push it
  already dispatched.

  Until this existed, an editor who does not read email and has not granted
  push found out about an `@mention`, a returned-to-draft or a task assignment
  only by reopening the document. The bell and `/editor/inbox` read these rows.

  ## It is not a second recipient decision

  A row is written from the *same* place, and on the same already-filtered
  recipient list, that enqueues the mail job — `KilnCMS.Notifications`'
  `notify/4` and `enqueue_comment/5`, past `wants?/2`. That is the whole point
  of persisting here rather than at the lifecycle call sites: a reviewer who
  muted `notify_on_review_request` must not find the event waiting in their
  inbox anyway, and two independent recipient rules would drift the first time
  one of them changed. See that module's moduledoc.

  ## The subject is a soft-polymorphic anchor, and a snapshot

  `content_type` + `content_id` (+ optional `block_id`) — the same anchor
  `KilnCMS.CMS.Comment` and `KilnCMS.CMS.Task` use, and soft for the same
  reason: it has to resolve across compiled content types and dynamic `:entry`
  types alike, and `block_id` names a block that lives in a jsonb array rather
  than a table. `KilnCMS.Notifications.Link.editor_path/1` turns the trio into the
  console deep link.

  `title` (and `excerpt`, for a comment) are **copied at notify time** rather
  than loaded on read. Two reasons: the inbox would otherwise load N records
  across M content types to render one list, and a notification is a record of
  something that happened — an item that silently re-titles itself when the
  document is renamed is no longer a description of the event. The same values
  already travel in the email body, so this stores nothing the recipient was
  not entitled to at the moment they were notified.

  ## Reading is self-only, with no admin bypass

  `authorize_if expr(user_id == ^actor(:id))` is the whole read policy. There
  is deliberately **no** `bypass actor_attribute_equals(:role, :admin)` — the
  sibling `KilnCMS.Accounts.PushSubscription` has one so an operator can see
  where a device came from, but a notification list is a reading history: who
  was named in which review note, which drafts someone is watching. A platform
  admin has no operational need for it, and an install's operator reading it is
  precisely the thing a notification centre should not make easy.

  With no actor, `^actor(:id)` templates to `nil` and the filter reduces to
  `user_id == NULL`, which no row satisfies — a system read returns nothing
  rather than everything.

  `:notify` is the counterpart: system-only, because it writes a row addressed
  to somebody *other* than whoever acted. It is gated by `forbid_if
  actor_present()` rather than called with `authorize?: false`, so the policy
  still runs and still decides — an authenticated request that reaches this
  action is refused by a rule a reader can see, instead of by the absence of
  one.
  """
  use Ash.Resource,
    otp_app: :kiln_cms,
    domain: KilnCMS.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias KilnCMS.Limits

  postgres do
    table "notifications"
    repo KilnCMS.Repo

    references do
      # A deleted account's notifications go with it: every row is addressed
      # to that one user and is meaningless without them.
      reference :user, on_delete: :delete
    end

    custom_indexes do
      # Every read this resource has is "one user's notifications, newest
      # first", within a tenant. One composite index serves the inbox list,
      # the dropdown, and — on its leading prefix — the unread count, which
      # additionally narrows on `read_at IS NULL`.
      index [:org_id, :user_id, :inserted_at], name: "notifications_user_lookup_index"
    end
  end

  actions do
    defaults [:read]

    create :notify do
      description "Record one notification for one recipient (system-only — see the moduledoc)."
      primary? true

      accept [
        :user_id,
        :event,
        :content_type,
        :content_id,
        :block_id,
        :title,
        :excerpt,
        :actor_name
      ]
    end

    read :for_user do
      description "The signed-in user's notifications, newest first (bell + inbox)."
      argument :user_id, :uuid, allow_nil?: false

      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :unread_for_user do
      description "The unread subset — what the bell's count is a count of."
      argument :user_id, :uuid, allow_nil?: false

      filter expr(user_id == ^arg(:user_id) and is_nil(read_at))
      prepare build(sort: [inserted_at: :desc])
    end

    update :mark_read do
      description "Mark one notification read. Idempotent: re-marking keeps the first timestamp."
      accept []
      require_atomic? false

      # Not `set_attribute`: the first read is when the recipient actually saw
      # it, and a second click (or a bulk sweep passing over an already-read
      # row) must not move that timestamp forward.
      change fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :read_at) do
          nil -> Ash.Changeset.force_change_attribute(changeset, :read_at, DateTime.utc_now())
          _already_read -> changeset
        end
      end
    end

    update :mark_unread do
      description "Put one notification back in the unread count."
      accept []
      require_atomic? false
      change set_attribute(:read_at, nil)
    end
  end

  policies do
    # Self-only, and nothing above it. No admin bypass — see the moduledoc.
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:update) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # The write addresses someone other than whoever acted, so it cannot be
    # authorized against the actor at all: it is the notifier's, and the
    # notifier has none. A call carrying an actor is a request that found its
    # way here, and is refused.
    policy action(:notify) do
      forbid_if actor_present()
      authorize_if always()
    end
  end

  # Multi-tenancy (epic #336): a notification belongs to the site whose content
  # it is about. A user who edits two sites sees each site's notifications in
  # that site's console and not in the other's — the same scoping every other
  # editorial read already has. `global?: true` outside strict mode keeps the
  # tenant optional, matching `KilnCMS.CMS.Task`.
  multitenancy do
    strategy :attribute
    attribute :org_id
    global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)
  end

  attributes do
    uuid_primary_key :id

    # The owning organization (epic #336). Set from the tenant on a scoped
    # create, else the default org; never accepted from input.
    attribute :org_id, :uuid do
      allow_nil? false
      default &KilnCMS.Accounts.default_org_id/0
      writable? false
      public? false
    end

    # Which event happened. The same names `KilnCMS.Notifications` dispatches
    # under, so one vocabulary covers all three channels — `:comment_mention`
    # included, which is a distinct event from `:comment_added` precisely
    # because being named is the stronger signal.
    attribute :event, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :submitted_for_review,
                    :published,
                    :returned_to_draft,
                    :comment_added,
                    :comment_resolved,
                    :comment_mention,
                    :task_assigned
                  ]
    end

    # Soft polymorphic reference to the content the event happened on (matches
    # Comment / Task / Consent / HistoryAnchor), not an FK — it has to reach
    # dynamic `:entry` types too.
    attribute :content_type, :string do
      allow_nil? false
      public? true
      constraints max_length: Limits.identifier()
    end

    attribute :content_id, :uuid, allow_nil?: false, public?: true

    # The block the event is anchored to, when there is one — a comment thread
    # or a block-anchored task. `nil` is a document-level event. Soft, like
    # `Comment.block_id`: blocks live in a jsonb array, not a table, so a
    # deleted block leaves the notification pointing at a document rather than
    # cascading away.
    attribute :block_id, :uuid do
      allow_nil? true
      public? true
    end

    # The subject's title as it read when the event happened — see the
    # moduledoc on why this is a snapshot.
    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: Limits.line()
    end

    # A taste of the comment, for comment events. Already truncated by
    # `KilnCMS.Notifications` to the same length the email uses.
    attribute :excerpt, :string do
      allow_nil? true
      public? true
      constraints max_length: Limits.paragraph()
    end

    # Who did it, by their chosen display name. Nil for actor-less events
    # (scheduled publishing, automation) — privacy #214: never the email
    # local-part.
    attribute :actor_name, :string do
      allow_nil? true
      public? true
      constraints max_length: Limits.line()
    end

    # When the recipient saw it. Nil = unread, which is what the bell counts.
    attribute :read_at, :utc_datetime_usec do
      allow_nil? true
      writable? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, KilnCMS.Accounts.User do
      allow_nil? false
      attribute_writable? true
    end
  end
end
