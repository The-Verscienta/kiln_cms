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
    end

    resource KilnCMS.Newsletter.Segment do
      define :create_segment, action: :create
      define :list_segments, action: :read
      define :get_segment, action: :read, get_by: [:id]
      define :update_segment, action: :update
      define :destroy_segment, action: :destroy
    end

    resource KilnCMS.Newsletter.SegmentMembership do
      define :add_to_segment, action: :create
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
  `:gated` — a non-public audience — or `:not_fired` when no `:web` artifact
  exists yet). Actual delivery happens asynchronously via the fan-out worker.
  """
  @spec send_as_newsletter(struct(), keyword()) :: {:ok, struct()} | {:error, atom()}
  def send_as_newsletter(document, opts \\ []) do
    with :ok <- ensure_sendable(document),
         {:ok, _html} <- artifact_html(document) do
      {:ok, send} =
        create_send(
          %{
            content_type: to_string(Firing.Engine.document_type(document)),
            content_id: document.id,
            subject: opts[:subject] || document.title,
            segment_id: opts[:segment_id],
            sent_by_id: opts[:actor] && opts[:actor].id
          },
          authorize?: false
        )

      %{"newsletter_send_id" => send.id}
      |> SendWorker.new()
      |> Oban.insert!()

      {:ok, send}
    end
  end

  # A document is safe to newsletter only when it is published *and*
  # world-readable. Gated/embargoed content is refused so restricted content
  # never leaks to an email list (the send question 2 decision).
  defp ensure_sendable(%{state: :published, audience: :public}), do: :ok
  defp ensure_sendable(%{state: :published}), do: {:error, :gated}
  defp ensure_sendable(_document), do: {:error, :not_published}

  # The email body is the already-fired, immutable published HTML — never the
  # live editable tree (same guarantee as public delivery).
  @doc false
  @spec artifact_html(struct() | NewsletterSend.t()) :: {:ok, String.t()} | {:error, :not_fired}
  def artifact_html(%NewsletterSend{content_type: type, content_id: id}) do
    # NewsletterSend isn't org-scoped yet (newsletter is scoped in a later PR),
    # so resolve the artifact under the default org (epic #336). Correct while the
    # single-org rollout guard is in force; revisit when NewsletterSend gains org_id.
    read_web_artifact(KilnCMS.Accounts.default_org_id(), String.to_existing_atom(type), id)
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
