defmodule KilnCMS.Links.Sweep do
  @moduledoc """
  Finds every outbound URL a site publishes, and queues the ones due a check
  (#474).

  Two stages, deliberately split: this one is all database, and
  `KilnCMS.Links.CheckWorker` is all network. Scanning is fast and safe to
  repeat; checking is slow, paced per domain, and must not be repeated more than
  it has to. Putting them in one job would mean a sweep that dies halfway
  through leaves the corpus half-scanned *and* the network half-asked.

  ## What it scans

  **Published records only**, across every compiled content type and the shared
  dynamic `Entry` tier — the same enumeration `KilnCMS.Firing.Sweep` and the
  governance index use. A draft's links are not yet anyone's problem, and
  checking them would spend a site's egress budget on prose that may never
  ship.

  ## Reconciliation by timestamp

  Every observed occurrence is stamped `last_seen_at`. When the scan finishes,
  rows for this org older than the run are deleted — which is simultaneously the
  handler for "the author removed that link", "the document was unpublished",
  "the document was deleted" and "the type was archived", none of which this
  module has to know about individually. A hook per case is four places to
  forget.

  Note the ordering that makes this safe: the delete only runs after a scan that
  reached the end. A sweep that raises partway leaves stale rows in the report
  rather than deleting every link it had not got to yet.

  ## What is queued, and what is not

  A URL is due when nothing has checked it, when it is not currently `:ok`, or
  when its last check has aged past the recheck window. Healthy links are
  re-checked weekly rather than nightly: they are the overwhelming majority, and
  a checker that asks every host about every working link every night is a
  checker sites start blocking.

  One job per **distinct URL**, not per occurrence — forty documents citing the
  same page cost one request.
  """

  require Ash.Query
  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Entry
  alias KilnCMS.CMS.ExternalLink
  alias KilnCMS.CMS.Fragments
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Links.CheckWorker
  alias KilnCMS.Links.Extract
  alias KilnCMS.Links.Settings

  # How long a healthy link is trusted before it is asked again.
  @recheck_after_hours 168

  # `Oban.insert_all` skips unique checks, so insert in modest chunks to keep any
  # single INSERT bounded — the same reasoning as `KilnCMS.Firing.Sweep`.
  @chunk 500

  @type counts :: %{
          observed: non_neg_integer(),
          pruned: non_neg_integer(),
          queued: non_neg_integer()
        }

  @doc """
  Sweep every site that has switched outbound checking on.

  Returns `%{org_id => counts}`. Sites that have not opted in are absent rather
  than present with zeroes — "we did nothing here" and "we found nothing here"
  are different answers.
  """
  @spec run() :: %{Ash.UUID.t() => counts()}
  def run do
    Map.new(Settings.enabled_org_ids(), &{&1, run_org(&1)})
  end

  @doc """
  Sweep one site, whether or not it has opted in.

  The opt-in is checked by the caller (`run/0`, `KilnCMS.Links.SweepWorker`) so
  that an operator can run one site by hand — `KilnCMS.Links.Sweep.run_org(id)`
  from a remote console — without first having to change its settings.
  """
  @spec run_org(Ash.UUID.t()) :: counts()
  def run_org(org_id) do
    started_at = DateTime.utc_now()

    observed = Enum.reduce(documents(org_id), 0, &(&2 + observe_document(&1, org_id)))
    pruned = prune(org_id, started_at)
    queued = enqueue_due(org_id)

    Settings.record_sweep(org_id)

    Logger.info(
      "link check: swept #{org_id} — #{observed} links seen, #{pruned} stale removed, " <>
        "#{queued} queued for checking"
    )

    %{observed: observed, pruned: pruned, queued: queued}
  end

  # Every published document as `{type_string, id, title, blocks}`. A stream per
  # resource rather than one big read: a corpus does not fit in memory and the
  # block tree is the largest column in the database.
  defp documents(org_id) do
    compiled =
      Enum.map(ContentTypes.all(), fn ct ->
        stream(ct.resource, org_id, fn _record -> to_string(ct.type) end)
      end)

    Stream.concat(compiled ++ [dynamic_documents(org_id)])
  end

  # The shared entry tier, labelled with each entry's public type name. An entry
  # whose definition no longer resolves is skipped: its editor URL would not
  # resolve either, so a report row pointing at it is a dead end.
  defp dynamic_documents(org_id) do
    case ContentTypes.dynamic_all(org_id) do
      [] ->
        []

      descriptors ->
        names = Map.new(descriptors, &{&1.definition.id, &1.type})
        stream(Entry, org_id, &names[&1.type_definition_id])
    end
  end

  defp stream(resource, org_id, type_fun) do
    resource
    |> Ash.Query.filter(state == :published)
    |> Ash.stream!(authorize?: false, tenant: org_id, stream_with: :full_read)
    |> Stream.flat_map(fn record ->
      case type_fun.(record) do
        nil ->
          []

        type ->
          [
            %{
              type: type,
              id: record.id,
              title: record.title,
              blocks: record.blocks,
              audience: Map.get(record, :audience)
            }
          ]
      end
    end)
  end

  defp observe_document(document, org_id) do
    document.blocks
    |> TypedBlocks.to_typed()
    |> Fragments.expand(org_id,
      audiences: audiences_for(document),
      ancestry: [{document.type, document.id}]
    )
    |> Extract.from_typed()
    |> Enum.count(&observe(&1, document, org_id))
  end

  defp audiences_for(%{audience: audience}) when audience in [nil, :public], do: []
  defp audiences_for(%{audience: audience}), do: [audience]

  defp observe(occurrence, document, org_id) do
    attrs = %{
      url: occurrence.url,
      block_index: occurrence.block_index,
      document_type: document.type,
      document_id: document.id,
      document_title: document.title
    }

    case Ash.create(ExternalLink, attrs, action: :observe, authorize?: false, tenant: org_id) do
      {:ok, _row} ->
        true

      {:error, reason} ->
        # One malformed URL must not abandon the rest of the document. The row
        # simply is not refreshed, so the prune below removes it and the next
        # sweep tries again.
        Logger.debug("link check: could not record #{occurrence.url}: #{inspect(reason)}")
        false
    end
  end

  # Counted before the delete rather than from the delete's own return: asking
  # `bulk_destroy` for its records means loading every stale row into memory to
  # count a number, which on the one site where the number is large is the site
  # that can least afford it.
  defp prune(org_id, started_at) do
    query = Ash.Query.filter(ExternalLink, last_seen_at < ^started_at)
    count = Ash.count!(query, authorize?: false, tenant: org_id)

    case Ash.bulk_destroy(query, :destroy, %{},
           authorize?: false,
           tenant: org_id,
           strategy: [:atomic, :stream],
           return_errors?: true
         ) do
      %Ash.BulkResult{status: :success} ->
        count

      %Ash.BulkResult{errors: errors} ->
        Logger.warning("link check: prune for #{org_id} reported #{inspect(errors)}")
        count
    end
  end

  defp enqueue_due(org_id) do
    stale_before = DateTime.add(DateTime.utc_now(), -@recheck_after_hours, :hour)

    ExternalLink
    |> Ash.Query.filter(
      is_nil(last_checked_at) or outcome != :ok or last_checked_at < ^stale_before
    )
    |> Ash.Query.sort(url_digest: :asc)
    |> Ash.Query.distinct([:url_digest])
    |> Ash.Query.select([:url, :url_digest])
    |> Ash.stream!(authorize?: false, tenant: org_id, stream_with: :full_read)
    |> Stream.map(&CheckWorker.new(%{"org_id" => org_id, "url" => &1.url}))
    |> Stream.chunk_every(@chunk)
    |> Enum.reduce(0, fn jobs, count ->
      Oban.insert_all(jobs)
      count + length(jobs)
    end)
  end

  @doc "How long a healthy link is trusted before it is checked again, in hours."
  @spec recheck_after_hours() :: pos_integer()
  def recheck_after_hours, do: @recheck_after_hours
end
