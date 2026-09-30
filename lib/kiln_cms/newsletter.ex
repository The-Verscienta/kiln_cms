defmodule KilnCMS.Newsletter do
  @moduledoc """
  Newsletters — send a published post to a segment of opted-in subscribers via
  the built-in MTA (`KilnCMS.Mail`).

  The Ash domain for the subscriber list, segments, and the campaign ledger,
  plus the dispatch entry point `send_as_newsletter/2`. Dispatch validates that
  the document is safe to blast (published and world-readable — gated/embargoed
  content is refused so it can't leak to an email list), records a
  `NewsletterSend`, and enqueues the fan-out worker. Delivery reuses the
  immutable fired `:web` artifact as the email body and the mail pipeline's
  DKIM signing, bounce-suppression, and greylist-aware retry.

  Phase 1 (issue #337): manual "send as newsletter", double opt-in, unsubscribe.
  Auto-on-publish and paid membership gating are Phase 2.
  """
  use Ash.Domain

  alias KilnCMS.Firing
  alias KilnCMS.Newsletter.NewsletterSend
  alias KilnCMS.Newsletter.Segment
  alias KilnCMS.Newsletter.SendWorker

  resources do
    resource KilnCMS.Newsletter.Subscriber do
      define :subscribe, action: :subscribe
      define :list_subscribers, action: :read
      define :get_subscriber, action: :read, get_by: [:id]
      define :subscriber_by_unsubscribe_token, action: :by_unsubscribe_token, args: [:token]
      define :subscriber_by_confirm_token, action: :by_confirm_token, args: [:token]
      define :confirm_subscriber, action: :confirm
      define :unsubscribe_subscriber, action: :unsubscribe
      define :confirmed_subscribers, action: :confirmed, args: [{:optional, :segment_id}]
      # System-only (`system/0`) — driven by billing, see TierSync.
      define :link_member_subscriber, action: :link_member, args: [:user_id]
      define :resubscribe_subscriber, action: :resubscribe
      define :subscribers_for_user, action: :for_user, args: [:user_id]
    end

    resource KilnCMS.Newsletter.Segment do
      define :create_segment, action: :create
      define :list_segments, action: :read
      define :get_segment, action: :read, get_by: [:id]
      define :update_segment, action: :update
      define :destroy_segment, action: :destroy
      # System-only (`system/0`) — the tier-backed lifecycle.
      define :create_tier_segment, action: :for_tier, args: [:tier_id, :audience]
      define :sync_managed_segment, action: :sync_managed
    end

    resource KilnCMS.Newsletter.SegmentMembership do
      define :add_to_segment, action: :create
      define :list_segment_memberships, action: :read
      define :remove_from_segment, action: :destroy
    end

    resource KilnCMS.Newsletter.NewsletterSend do
      define :create_send, action: :create
      define :get_send, action: :read, get_by: [:id]
      define :list_sends, action: :read
      define :recent_sends, action: :recent
      define :mark_sending, action: :mark_sending
      define :mark_sent, action: :mark_sent
      define :mark_failed, action: :mark_failed
      define :record_sent, action: :record_sent
      define :record_failed, action: :record_failed
    end
  end

  @doc """
  The actor the newsletter's own machinery runs as (#1659): a
  `KilnCMS.SystemActor` labelled `:newsletter`.

  Two callers use it. The send pipeline (`SendWorker`, `MailWorker`) reads
  the campaign and its confirmed subscribers and keeps the campaign's
  counters; `TierSync` keeps tier-backed segments and their members in step
  with billing. Each resource admits it by action name (see
  `docs/policy-matrix.md`, "The system actor"): on `NewsletterSend` the read
  and the fan-out bookkeeping, never `destroy` or `mark_failed`; on
  `Subscriber` the reads (`read`, `confirmed`) and `link_member`, never a
  consent change.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system, do: KilnCMS.SystemActor.resolve(:newsletter)

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process, so a test can take the grant away and prove the send pipeline's
  # reads fail CLOSED: a refused subscriber list must retry, never fan out to
  # nobody and mark the campaign sent. Process-local; nothing on a request
  # path calls it.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun), do: KilnCMS.SystemActor.with_override(:newsletter, actor, fun)

  @doc """
  Send a published document to subscribers as a newsletter.

  `document` is a published content struct (typically a post). Options:

    * `:segment_id` — restrict to one segment; omit to send to every confirmed
      subscriber.
    * `:subject` — email subject; defaults to the document title.
    * `:actor` — who is sending. The campaign is written **under this actor's
      authorization** (#1655): `NewsletterSend`'s policy admits an admin of the
      document's org, and — for the automation path only —
      `%KilnCMS.SystemActor{}`. A person's id is recorded as `sent_by_id`.
      Pass a freshly-read actor: the policy decides on the struct it is given,
      so a stale one carries a revoked role with it (see
      `KilnCMSWeb.NewsletterLive`, which reloads before sending).

  Returns `{:ok, %NewsletterSend{}}` once the campaign is queued, or
  `{:error, reason}` when the document isn't safe to send (`:not_published`,
  `%Ash.Error.Forbidden{}` when the actor may not create the campaign or read
  the segment it names,
  `:gated` — a non-public audience with no entitled tier segment targeted,
  `:no_such_segment`, `:no_recipients` when the audience has no confirmed
  subscriber (#1775 — nothing is recorded, so the publish revision's
  automation ledger entry is not spent on an empty campaign), or `:not_fired`
  when no `:web` artifact exists yet).

  Gated content may be sent **only** to a tier-backed segment whose tier grants
  exactly that audience (#337 Phase 2); a hand-built segment is always refused. Actual delivery happens asynchronously via the fan-out worker.
  """
  @spec send_as_newsletter(struct(), keyword()) ::
          {:ok, struct()} | {:error, atom() | Ash.Error.t()}
  def send_as_newsletter(document, opts \\ []) do
    automation = opts[:automation]

    with {:ok, segment} <- resolve_segment(opts[:segment_id], document.org_id, opts[:actor]),
         :ok <- ensure_sendable(document, segment),
         :ok <- ensure_recipients(document.org_id, opts[:segment_id], opts[:actor]),
         {:ok, _html} <- artifact_html(document) do
      # Ledger row + fan-out job commit in ONE transaction (Oban jobs are
      # Postgres rows), so a crash between them can't strand a campaign that
      # the automation dedupe would then permanently block as :already_sent.
      # Notifications are collected and emitted after commit (the Ash idiom
      # for actions inside a wrapping transaction).
      KilnCMS.Repo.transaction(fn -> create_and_enqueue(document, opts, automation) end)
      |> settle_transaction()
    end
  end

  defp create_and_enqueue(document, opts, automation) do
    create_send(
      %{
        content_type: to_string(Firing.Engine.document_type(document)),
        content_id: document.id,
        subject: opts[:subject] || document.title,
        segment_id: opts[:segment_id],
        # Matched, not dereferenced: a `SystemActor` has no `:id` (#1402).
        sent_by_id: actor_id(opts[:actor]),
        # Automation provenance + dedupe key (#376) — nil for manual sends.
        automation_rule_id: automation && automation.rule_id,
        content_published_at: automation && automation.published_at
      },
      # Authorized as the caller (#1655). This used to be `authorize?: false`
      # behind the console's tier check alone, which a demoted global admin's
      # stale struct still passed; an email cannot be unsent, so the policy is
      # the gate and the LiveView check is UX.
      actor: opts[:actor],
      # The campaign lands in the document's site (epic #336).
      tenant: document.org_id,
      return_notifications?: true
    )
    |> dedupe_conflict()
    |> case do
      {:ok, send, notifications} ->
        # `org_id` rides into the worker args so the fan-out runs under the
        # send's tenant.
        %{"newsletter_send_id" => send.id, "org_id" => send.org_id}
        |> SendWorker.new()
        |> Oban.insert!()

        {send, notifications}

      {:error, reason} ->
        KilnCMS.Repo.rollback(reason)
    end
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil

  defp settle_transaction({:ok, {send, notifications}}) do
    Ash.Notifier.notify(notifications)
    {:ok, send}
  end

  # A failing create inside the wrapping transaction rolls back with the
  # changeset itself (Ash's own rollback) — classify its errors the same way
  # as a returned error.
  defp settle_transaction({:error, %Ash.Changeset{errors: errors}} = error) do
    if dedupe_errors?(errors), do: {:error, :already_sent}, else: error
  end

  defp settle_transaction({:error, _reason} = error), do: error

  # An automation-driven campaign for the same {rule, content, publish revision}
  # already exists (the `:automation_dedupe` identity) — a re-fired event or
  # re-delivered job, not a new publish. Matched structurally on the identity's
  # fields (the `KilnCMS.History.seq_conflict?/1` idiom), never on error text.
  defp dedupe_conflict({:error, %Ash.Error.Invalid{errors: errors} = error}) do
    if dedupe_errors?(errors), do: {:error, :already_sent}, else: {:error, error}
  end

  defp dedupe_conflict(other), do: other

  defp dedupe_errors?(errors) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{field: field} ->
        field in [:automation_rule_id, :content_id, :content_published_at]

      %{constraint_name: "newsletter_sends_automation_dedupe_index"} ->
        true

      _ ->
        false
    end)
  end

  # A document is safe to newsletter when it is published AND either
  # world-readable, or gated to exactly the audience the target segment is
  # entitled to by its paid tier (#337 Phase 2).
  #
  # The second clause binds `audience` TWICE — once from the document, once from
  # the segment — so it is a literal equality match in the function head with no
  # comparison logic to get wrong. It requires `managed_by: :tier`, so:
  #
  #   * a HAND-BUILT segment can never receive gated content, no matter what
  #     `audience` label an admin puts on it (that label grants nothing);
  #   * a nil segment ("every confirmed subscriber") falls through to the same
  #     refusal, since that is an arbitrary list by definition.
  #
  # Clause order preserves the existing `:gated`-before-`:not_published`
  # precedence.
  # A passphrase-locked document (#496) is never sendable, whatever its audience
  # or segment. A newsletter carries the document's body into inboxes, which is
  # the one delivery channel with no unlock step in front of it — sending one
  # would hand the content to every subscriber and leave the lock protecting an
  # empty room. Refused as `:gated`, the existing "you may not send this" answer.
  defp ensure_sendable(%{access_password_hash: hash}, _segment) when not is_nil(hash),
    do: {:error, :gated}

  defp ensure_sendable(%{state: :published, audience: :public}, _segment), do: :ok

  defp ensure_sendable(%{state: :published, audience: audience}, %Segment{
         managed_by: :tier,
         audience: audience
       }),
       do: :ok

  defp ensure_sendable(%{state: :published}, _segment), do: {:error, :gated}
  defp ensure_sendable(_document, _segment), do: {:error, :not_published}

  # The send guard needs the segment itself, not just its id. Read as the
  # SENDER (#1659), the same actor the campaign is created under: an admin of
  # the site from the console, or the automation's system actor, which
  # `Segment` admits for `:read`. It used to be `authorize?: false`, which let
  # an actor who could not see the segment still have its tier audience
  # decide whether gated content went out.
  #
  # `authorize_with: :error`, because a refused read under the filter answers
  # `nil`, and `nil` is "no such segment". Refused is not absent: the caller
  # gets the Forbidden, and the automation worker retries on it rather than
  # reading a lost grant as a deleted segment. Either way nothing is sent.
  defp resolve_segment(nil, _org_id, _actor), do: {:ok, nil}

  defp resolve_segment(segment_id, org_id, actor) do
    case get_segment(segment_id,
           actor: actor,
           authorize_with: :error,
           tenant: org_id,
           not_found_error?: false
         ) do
      {:ok, nil} -> {:error, :no_such_segment}
      {:ok, segment} -> {:ok, segment}
      {:error, %Ash.Error.Forbidden{} = error} -> {:error, error}
      {:error, _reason} -> {:error, :no_such_segment}
    end
  end

  @doc """
  Whether the audience a campaign would target has at least one confirmed
  subscriber (#1775).

  `segment_id` is the campaign's segment, or `nil` for every confirmed
  subscriber on the site. Read as `actor` — the sender — with
  `authorize_with: :error` (#1659): a refused read under the filter would
  answer an empty list, which is indistinguishable from "nobody to send to",
  so a refusal comes back as `{:error, %Ash.Error.Forbidden{}}` instead of
  `{:ok, false}`.

  A one-row probe, not a count: `Ash.count/2` cannot tell a refusal from zero.
  """
  @spec has_recipients?(Ash.UUID.t(), Ash.UUID.t() | nil, term()) ::
          {:ok, boolean()} | {:error, term()}
  def has_recipients?(org_id, segment_id, actor) do
    case confirmed_subscribers(segment_id,
           actor: actor,
           authorize_with: :error,
           tenant: org_id,
           query: [limit: 1, select: [:id]]
         ) do
      {:ok, recipients} -> {:ok, recipients != []}
      {:error, _error} = error -> error
    end
  end

  # Refuse a campaign with nobody to send it to (#1775). Checked before the
  # ledger row is written: an empty campaign used to be recorded, queued and
  # marked `:sent` to zero recipients, and for an automation rule it spent
  # the one send per publish revision, so confirming subscribers afterwards
  # could not send that revision. Fails CLOSED on a refused read (see
  # `has_recipients?/3`). The fan-out worker re-resolves the list when it
  # runs, so this is a preflight, not the recipient set.
  #
  # A person is read as themselves. The automation's system actor opens
  # campaigns but holds no grant on subscribers (#1747 gives each subsystem
  # only its own actions), so its preflight reads as the newsletter's own
  # actor — the one `SendWorker` resolves the same list with a moment later.
  defp ensure_recipients(org_id, segment_id, actor) do
    case has_recipients?(org_id, segment_id, recipient_reader(actor)) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :no_recipients}
      {:error, _error} = error -> error
    end
  end

  defp recipient_reader(%KilnCMS.SystemActor{}), do: system()
  defp recipient_reader(actor), do: actor

  # The email body is the already-fired, immutable published HTML — never the
  # live editable tree (same guarantee as public delivery).
  @doc false
  @spec artifact_html(struct() | NewsletterSend.t()) :: {:ok, String.t()} | {:error, :not_fired}
  def artifact_html(%NewsletterSend{org_id: org_id, content_type: type, content_id: id}) do
    # Resolve the artifact under the campaign's own site (epic #336).
    read_web_artifact(org_id, String.to_existing_atom(type), id)
  end

  def artifact_html(document) do
    read_web_artifact(document.org_id, Firing.Engine.document_type(document), document.id)
  end

  defp read_web_artifact(org_id, type, id) do
    case Firing.Engine.read(org_id, type, id, :web) do
      {:ok, %{"html" => html}} -> {:ok, html}
      _ -> {:error, :not_fired}
    end
  end
end
