defmodule KilnCMS.Firing do
  @moduledoc """
  The firing domain (Kiln v2 — decision D9).

  Holds `PublishedArtifact` — the immutable, pre-serialized output a document
  compiles to on publish. `KilnCMS.Firing.Engine` is the orchestrator (compile +
  upsert + cache + broadcast); `KilnCMS.Firing.Cache` is the two-tier read cache.
  `SyncExposure` is the sync API's record of which documents it has disclosed
  (`KilnCMS.Firing.Sync`).

  ## Re-firing a record from an overlay

  `refire/3` (and `refire!/3`) is the covered way for an overlay to re-fire
  documents it knows are stale when Kiln doesn't (#2048) — an article whose
  fired card was built from another install's API, when that install's signed
  webhook says the card's source changed:

      KilnCMS.Firing.refire!("article", [article_id],
        actor: KilnCMS.SystemActor.new(:overlay),
        tenant: org_id
      )
      #=> 1

  `document_type` is a content type's public name (`"page"`, `"post"`, a
  compiled overlay type, a dynamic type's name); `document_ids` is a list.
  Each id gets the normal fire job, so it fires exactly as a publish would —
  every surface's artifact, the reference graph, and the wave to every
  published document that embeds it — and then, as an edit of live content
  does, its delivery cache is dropped and `<type>.updated` is dispatched: the
  webhook endpoints, automation, federation and the CDN purge. A document that
  is not published fires and dispatches nothing. The return value is how many
  fires were queued; an id that already has a re-fire pending is not queued
  twice.

  It needs a `tenant:` (the org whose documents to fire) and an actor:
  `KilnCMS.SystemActor.new(:overlay)` for an overlay's own code with no person
  behind it, or an editor or admin of that org. Anything else is
  `Ash.Error.Forbidden`. The call only queues jobs — the fire itself runs on the
  `:firing` queue as the firing engine.
  """
  use Ash.Domain

  resources do
    resource KilnCMS.Firing.PublishedArtifact do
      define :list_artifacts, action: :read
      define :artifacts_for, action: :for_document, args: [:document_type, :document_id]
      define :get_artifact, action: :get_surface, args: [:document_type, :document_id, :surface]

      define :artifacts_for_documents,
        action: :for_documents,
        args: [:document_type, :document_ids, :surface]

      define :upsert_artifact, action: :upsert

      define :refire, action: :refire, args: [:document_type, :document_ids]
    end

    resource KilnCMS.Firing.ReferenceEdge do
      define :edges_from, action: :from_source, args: [:from_type, :from_id]
      define :edges_to, action: :to_target, args: [:to_type, :to_id]
      define :upsert_edge, action: :upsert
    end

    resource KilnCMS.Firing.SyncExposure do
      define :record_sync_exposure, action: :record
      define :sync_exposures_for, action: :for_documents, args: [:document_ids]
    end
  end
end
