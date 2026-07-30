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
      # System-only (`authorize?: false`) — driven by billing, see TierSync.
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
      # System-only (`authorize?: false`) — the tier-backed lifecycle.
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
  Send a published document to subscribers as a newsletter.

  `document` is a published content struct (typically a post). Options:

    * `:segment_id` — restrict to one segment; omit to send to every confirmed
      subscriber.
    * `:subject` — email subject; defaults to the document title.
    * `:actor` — the admin triggering the send (recorded on the ledger).

  Returns `{:ok, %NewsletterSend{}}` once the campaign is queued, or
  `{:error, reason}` when the document isn't safe to send (`:not_published`,
  `:gated` — a non-public audience with no entitled tier segment targeted,
  `:no_such_segment`, or `:not_fired` when no `:web` artifact exists yet).

  Gated content may be sent **only** to a tier-backed segment whose tier grants
  exactly that audience (#337 Phase 2); a hand-built segment is always refused. Actual delivery happens asynchronously via the fan-out worker.
  """
  @spec send_as_newsletter(struct(), keyword()) ::
          {:ok, struct()} | {:error, atom() | Ash.Error.t()}
  def send_as_newsletter(document, opts \\ []) do
    automation = opts[:automation]

    with {:ok, segment} <- resolve_segment(opts[:segment_id], document.org_id),
         :ok <- ensure_sendable(document, segment),
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
        sent_by_id: opts[:actor] && opts[:actor].id,
        # Automation provenance + dedupe key (#376) — nil for manual sends.
        automation_rule_id: automation && automation.rule_id,
        content_published_at: automation && automation.published_at
      },
      authorize?: false,
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
  defp ensure_sendable(%{state: :published, audience: :public}, _segment), do: :ok

  defp ensure_sendable(%{state: :published, audience: audience}, %Segment{
         managed_by: :tier,
         audience: audience
       }),
       do: :ok

  defp ensure_sendable(%{state: :published}, _segment), do: {:error, :gated}
  defp ensure_sendable(_document, _segment), do: {:error, :not_published}

  # The send guard needs the segment itself, not just its id. Read as the system:
  # authorization already happened at the LiveView/automation layer, matching the
  # rest of this funnel.
  defp resolve_segment(nil, _org_id), do: {:ok, nil}

  defp resolve_segment(segment_id, org_id) do
    case get_segment(segment_id, authorize?: false, tenant: org_id, not_found_error?: false) do
      {:ok, nil} -> {:error, :no_such_segment}
      {:ok, segment} -> {:ok, segment}
      {:error, _reason} -> {:error, :no_such_segment}
    end
  end

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
