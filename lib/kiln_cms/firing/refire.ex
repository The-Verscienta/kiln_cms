defmodule KilnCMS.Firing.Refire do
  @moduledoc """
  Re-fire named documents on request — the body of `KilnCMS.Firing.refire/3`
  (#2048).

  For an overlay that knows a fired artifact is stale when Kiln does not: an
  article embeds a card built at fire time from another install's API, and that
  install's signed webhook says the card's source changed. Nothing in this
  install was edited, so nothing would re-fire.

  Each id gets the normal `KilnCMS.Firing.FireWorker` job, flagged
  `"refire" => true`. The worker fires it exactly as a publish would — the
  artifacts, the reference rebuild, the wave to every document embedding it
  (`KilnCMS.Firing.RefireWorker`), search indexing — and, because of the flag,
  then does what an edit of live content does around a fire: busts the
  document's delivery cache and dispatches `<type>.updated`
  (`KilnCMS.Webhooks.dispatch/4`), which reaches the webhook endpoints,
  automation, federation and the CDN purge. It dispatches *after* the fire, so a
  receiver or the CDN that refetches on the event gets the new body.

  A document that is not published fires nothing and dispatches nothing: the
  worker treats it as settled-absent, as it does for any fire.
  """

  alias KilnCMS.Firing.{FireWorker, References}

  # A refire must not collapse into a fire that is already *executing*: that
  # one may have built its cards from the data the overlay was just told is
  # stale. Pending jobs still dedupe, keyed with the flag so a plain fire
  # queued by a publish never swallows the refire's `updated` dispatch.
  @unique [
    period: 60,
    keys: [:org_id, :type, :id, :refire],
    states: [:scheduled, :available, :retryable, :suspended]
  ]

  @doc """
  Queue a re-fire of each of `ids` (documents of `type`) in `org_id`. Returns
  `{:ok, count}`, the number of fires queued — an id that already has a refire
  pending is not queued twice — or `{:error, {:unknown_type, type}}`.

  `type` is a content type's public name, as a string or an atom: `"page"`,
  `:post`, a compiled overlay type, or a dynamic type's name (`"recipe"`).
  """
  @spec run(Ash.UUID.t(), atom() | String.t(), [Ash.UUID.t()]) ::
          {:ok, non_neg_integer()} | {:error, {:unknown_type, term()}}
  def run(org_id, type, ids) when is_binary(org_id) and is_list(ids) do
    case References.type_atom(to_string(type)) do
      nil ->
        {:error, {:unknown_type, type}}

      storage_type ->
        {:ok, ids |> Enum.uniq() |> Enum.count(&enqueue(org_id, storage_type, &1))}
    end
  end

  defp enqueue(org_id, type, id) do
    %{"org_id" => org_id, "type" => to_string(type), "id" => id, "refire" => true}
    |> FireWorker.new(unique: @unique)
    |> Oban.insert!()
    |> then(&(not &1.conflict?))
  end
end
