defmodule KilnCMS.OEmbed.ResolveWorker do
  @moduledoc """
  Resolves oEmbed metadata for a document's embed blocks and writes it back
  (#489).

  Enqueued by `KilnCMS.CMS.Changes.EnqueueOEmbed` after a save that left an
  embed block unresolved. Runs off the write path so a provider's latency is
  never an editor's.

  ## Fetch first, then re-read, then apply

  Writing a *whole* block list back is the dangerous part: an outbound request
  takes seconds, and `:autosave` is one of the actions that enqueues this, so an
  editor typing during that window is the normal case rather than the rare one.
  A read-modify-write around the fetch would silently drop every block they
  added — with `optimistic_lock` deliberately off, nothing would even error.

  So the order is: resolve the URLs (slow, no lock held), re-read the document,
  and apply the results to whatever is stored **now**, matching each block by
  its stable id *and* its URL. A block edited during the fetch simply does not
  match, and keeps whatever the editor gave it.

  ## It writes through `:set_oembed_metadata`, never `:update`

  `:update` carries `optimistic_lock`, `NotifyWebhooks` and `FireArtifacts`, and
  is not in PaperTrail's `ignore_actions`. Using it would make a background
  metadata write emit an `updated` webhook to every subscriber, cut a history
  version attributed to nobody, and bump `lock_version` — which, because the
  resolve is enqueued from `:autosave` too, would land mid-typing and turn an
  editor's next autosave into a `StaleRecord`.

  Re-firing is then done *deliberately*, and only for a published document,
  because the card does have to reach delivery.

  ## Nothing here is worth a retry

  A provider that is down, rate-limiting, or has never heard of the URL leaves
  the block exactly as it was — a bare-URL figure — and the job succeeds.
  Retrying the whole document because one embed of five did not resolve would
  re-fetch the four that did.

  It is also why `resolved_at` is stamped only alongside real metadata. Stamping
  it on every attempt would make "did anything change?" always true, so a
  provider that returns no title would write, re-enqueue, resolve and write
  again — a loop held back only by Oban's uniqueness window.

  What *does* fail the job is being unable to write the document, which is a
  real fault.
  """
  # Uniqueness deliberately excludes `:completed`. Oban's default states include
  # it, which would mean an editor who pastes a different URL into an embed
  # within 60 seconds of the last resolve gets no re-resolve at all — the stale
  # card would sit there until some later save happened to fall outside the
  # window. What this needs to prevent is a *pile-up* of pending duplicates, not
  # a legitimate second resolve.
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 60,
      # `:incomplete` is Oban's own name for "everything except completed,
      # cancelled and discarded" — spelling the list out drifts the day Oban
      # adds a state, which it warns about.
      states: :incomplete,
      keys: [:org_id, :id]
    ]

  alias KilnCMS.Blocks.Embed
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.OEmbed

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"org_id" => org_id, "resource" => resource, "id" => id}}) do
    case Ash.get(String.to_existing_atom(resource), id, authorize?: false, tenant: org_id) do
      {:ok, record} -> resolve_and_write(record, org_id)
      # A document deleted between enqueue and run is not a failure.
      {:error, _reason} -> :ok
    end
  end

  defp resolve_and_write(record, org_id) do
    case resolve_urls(record) do
      resolved when map_size(resolved) == 0 ->
        :ok

      resolved ->
        # Re-read *after* the fetch: `record` is now seconds stale, and writing
        # its block list back would delete anything an editor added meanwhile.
        case Ash.get(record.__struct__, record.id, authorize?: false, tenant: org_id) do
          {:ok, current} -> apply_and_write(current, resolved, org_id)
          {:error, _reason} -> :ok
        end
    end
  end

  # URL → metadata, for every embed that wants resolving. One request per
  # distinct URL, not per block.
  defp resolve_urls(record) do
    record.blocks
    |> TypedBlocks.to_typed()
    |> Enum.filter(&needs_resolution?/1)
    |> Enum.map(& &1.url)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn url, acc ->
      case metadata(url, OEmbed.resolve(url)) do
        nil -> acc
        metadata -> Map.put(acc, url, metadata)
      end
    end)
  end

  defp apply_and_write(record, resolved, org_id) do
    typed = TypedBlocks.to_typed(record.blocks)

    applied =
      Enum.map(typed, fn
        %Embed{} = block ->
          # Matched on the URL as it stands *now*. A block whose URL the editor
          # changed during the fetch does not match, so it keeps their value and
          # the next save enqueues a fresh resolve for it.
          case needs_resolution?(block) && resolved[block.url] do
            nil -> block
            false -> block
            metadata -> struct(block, metadata)
          end

        block ->
          block
      end)

    if applied == typed, do: :ok, else: write(record, applied, org_id)
  end

  defp needs_resolution?(%Embed{} = block),
    do: OEmbed.resolvable?(block.url) and not Embed.fresh?(block)

  defp needs_resolution?(_block), do: false

  # `resolved_at`/`resolved_url` ride *with* the metadata rather than being
  # stamped on every attempt — see the moduledoc on the write loop that would
  # otherwise be. A response carrying no title is not metadata: a card needs
  # one, so nothing is stored and the block stays a bare figure.
  defp metadata(url, {:ok, %{title: title} = card}) when is_binary(title) do
    card
    |> Map.put(:resolved_url, url)
    |> Map.put(:resolved_at, DateTime.to_iso8601(DateTime.utc_now()))
  end

  defp metadata(url, {:ok, _titleless}) do
    Logger.debug("oembed: #{url} resolved without a title; leaving it bare")
    nil
  end

  defp metadata(url, {:error, reason}) do
    # Debug, not warning: an unresolvable embed is an ordinary outcome — a
    # private video, a deleted post, a provider having an afternoon — and
    # logging it louder would make normal editing noisy.
    Logger.debug("oembed: #{url} did not resolve: #{inspect(reason)}")
    nil
  end

  defp write(record, blocks, org_id) do
    record
    |> Ash.Changeset.for_update(:set_oembed_metadata, %{blocks: blocks},
      authorize?: false,
      tenant: org_id
    )
    |> Ash.update()
    |> case do
      {:ok, updated} ->
        refire(updated)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The card has to reach delivery, and `:set_oembed_metadata` deliberately does
  # not fire artifacts. Only for a published document — a draft's artifact is
  # built when it publishes.
  defp refire(%{state: :published} = record) do
    type = KilnCMS.Firing.Engine.document_type(record)

    %{"org_id" => record.org_id, "type" => to_string(type), "id" => record.id}
    |> KilnCMS.Firing.FireWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> Logger.error("oembed: re-fire enqueue failed: #{inspect(reason)}")
    end
  end

  defp refire(_record), do: :ok
end
