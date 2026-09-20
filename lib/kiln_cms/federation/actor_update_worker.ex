defmodule KilnCMS.Federation.ActorUpdateWorker do
  @moduledoc """
  Tells a site's followers that its actor changed — today, that it was re-keyed
  (#1487) — by fanning an actor `Update` out through the ordinary delivery
  ledger (`KilnCMS.Federation.deliver_to_followers/4`).

  Enqueued by `SiteFederation`'s `:rekey` action **inside its transaction**, so
  the job becomes visible only once the new key is committed and `/actor`
  serves it. The document it sends is read here, at run time, not captured at
  enqueue: a second re-key before this runs is simply the key this sends.

  Each delivery is signed by `DeliveryWorker` with the site's key as it stands
  when that delivery runs — the new one. A receiver whose cached key is the
  old one fails that signature and, if it behaves like Mastodon, re-fetches the
  actor and then accepts the `Update`; the `Update` is as much a nudge to
  re-fetch as it is a message.

  A site that is switched off, or whose key the vault cannot open, sends
  nothing: its followers learn the new key from the actor document the next
  time a delivery fails verification.
  """
  # Not unique: two re-keys in quick succession send two `Update`s, both
  # carrying whatever key is current when each runs — redundant, never wrong.
  # Deduplicating would need to exclude an *executing* job (it has already read
  # its document), which Oban's uniqueness does not allow.
  use Oban.Worker, queue: :federation, max_attempts: 3

  alias KilnCMS.Federation
  alias KilnCMS.Federation.Activity
  alias KilnCMS.Federation.Actor

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id}}) do
    case Federation.active_settings(org_id, require_key?: true) do
      {:ok, settings} ->
        settings
        |> Actor.document()
        |> Activity.update_actor(Actor.identity(settings))
        |> Federation.deliver_to_followers(:update, nil, org_id)

      _off_or_unreadable ->
        :ok
    end
  end
end
