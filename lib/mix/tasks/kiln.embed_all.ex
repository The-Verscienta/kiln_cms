defmodule Mix.Tasks.Kiln.EmbedAll do
  @shortdoc "Enqueue embedding jobs for all existing content (semantic search backfill)"
  @moduledoc """
  Enqueues a `KilnCMS.Search.EmbeddingWorker` for every existing Page, Post,
  and dynamic Entry so their semantic embeddings are (re)computed in the
  background, and a `KilnCMS.Search.TagEmbeddingWorker` for every tag (the
  tag leg of hybrid search ranks by tag-name vectors). Run once after enabling semantic search, or after changing the
  embedding model (e.g. switching to a multilingual model — see
  `docs/semantic-search-plan.md`).

      mix kiln.embed_all
      mix kiln.embed_all --blocks

  No-op (with a notice) when semantic search is disabled.

  ## Options

    * `--blocks` — also re-embed the **block** index (`KilnCMS.Search.BlockEmbedding`,
      the block leg of hybrid search, related content and near-duplicates):
      one forced `KilnCMS.Search.BlockEmbeddingWorker` per published document.
      Needed after any change to the embedding space — model, pooling or
      `document_prefix`. Without it the block index stays in the old space:
      the fire path re-indexes a block only when its text changes, so a sweep
      (`mix kiln.refire_all`) re-embeds nothing either. Forced jobs ignore the
      stored content hashes, and they run on the `:search` queue without
      re-firing anything else. Only published documents have block rows
      (blocks are indexed on fire), so drafts are not enqueued.
  """
  use Mix.Task

  alias KilnCMS.CMS
  alias KilnCMS.Search
  alias KilnCMS.Search.BlockEmbeddingWorker
  alias KilnCMS.Search.EmbeddingWorker

  require Ash.Query

  @requirements ["app.start"]

  # Every embeddable content tier: the compiled Page/Post plus the shared
  # dynamic entry tier (D17), so a re-embed after a model change covers
  # admin-defined types too.
  @sources [
    {KilnCMS.CMS.Page, &CMS.list_pages!/1},
    {KilnCMS.CMS.Post, &CMS.list_posts!/1},
    {KilnCMS.CMS.Entry, &CMS.list_entries!/1}
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [blocks: :boolean])

    if Search.semantic?() do
      count = Enum.reduce(@sources, 0, &enqueue_source/2)
      tags = enqueue_tags()

      Mix.shell().info(
        "Enqueued embedding jobs for #{count} content record(s) and #{tags} tag(s)."
      )

      if opts[:blocks] do
        blocks = enqueue_blocks()

        Mix.shell().info(
          "Enqueued forced block re-embedding for #{blocks} published document(s)."
        )
      end
    else
      Mix.shell().info(
        "Semantic search is disabled (config :kiln_cms, KilnCMS.Search, semantic: false). " <>
          "Enable it first; nothing enqueued."
      )
    end
  end

  # Tag-name vectors back the tag leg (`KilnCMS.Search.TagEmbeddingWorker`);
  # before that leg they were written lazily by the suggestion panel, so an
  # existing site has most of its tags unembedded until this runs.
  defp enqueue_tags do
    tags =
      Enum.flat_map(KilnCMS.Accounts.list_org_ids(), fn org_id ->
        # authorize?: false — an operator backfill over every org's tags
        # (#1659); the index must see all of them, and a standing system-actor
        # grant on `Tag` for one mix task would outlive it. Ids only.
        CMS.list_tags!(authorize?: false, tenant: org_id, query: [select: [:id, :org_id]])
      end)

    tags
    |> Enum.map(
      &KilnCMS.Search.TagEmbeddingWorker.new(%{"org_id" => &1.org_id, "tag_id" => &1.id})
    )
    |> Enum.chunk_every(500)
    |> Enum.each(&Oban.insert_all/1)

    length(tags)
  end

  defp enqueue_source({resource, lister}, acc) do
    # Strict tenancy (#419): list per org (the reads require a tenant). Only ids
    # (+ the tenant, #336) are needed — don't drag blocks/search_text/embedding.
    records =
      Enum.flat_map(KilnCMS.Accounts.list_org_ids(), fn org_id ->
        # authorize?: false — an operator backfill over every org's content
        # (#1659): a CONTENT read under the #1402 argument, drafts included on
        # purpose (they are searchable in the editor). Ids only.
        lister.(authorize?: false, tenant: org_id, query: [select: [:id, :org_id]])
      end)

    records
    |> Enum.map(fn %{id: id, org_id: org_id} ->
      EmbeddingWorker.new(%{"org_id" => org_id, "resource" => to_string(resource), "id" => id})
    end)
    |> Enum.chunk_every(500)
    |> Enum.each(&Oban.insert_all/1)

    acc + length(records)
  end

  # One forced `BlockEmbeddingWorker` per published document, every org and
  # every storage tier with blocks — the same set and the same query as
  # `KilnCMS.Firing.Sweep`, minus the re-fire: only the block index is stale
  # after an embedding-space change, so re-rendering every artifact would be
  # work for nothing.
  defp enqueue_blocks do
    for {type, resource} <- KilnCMS.CMS.ContentTypes.blocks_resources(),
        org_id <- KilnCMS.Accounts.list_org_ids(),
        reduce: 0 do
      acc ->
        # authorize?: false — as in `Firing.Sweep.sweep_org/3` (#1402): one
        # tenant, `state == :published`, ids only, and they leave as job args.
        resource
        |> Ash.Query.filter(state == :published)
        |> Ash.Query.select([:id, :org_id])
        |> Ash.stream!(authorize?: false, tenant: org_id, stream_with: :full_read)
        |> Stream.map(fn record ->
          BlockEmbeddingWorker.new(%{
            "org_id" => record.org_id,
            "type" => to_string(type),
            "id" => record.id,
            "force" => true
          })
        end)
        |> Stream.chunk_every(500)
        |> Enum.reduce(acc, fn jobs, count ->
          Oban.insert_all(jobs)
          count + length(jobs)
        end)
    end
  end
end
