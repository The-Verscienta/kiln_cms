defmodule KilnCMS.Firing do
  @moduledoc """
  The firing domain (Kiln v2 — decision D9).

  Holds `PublishedArtifact` — the immutable, pre-serialized output a document
  compiles to on publish. `KilnCMS.Firing.Engine` is the orchestrator (compile +
  upsert + cache + broadcast); `KilnCMS.Firing.Cache` is the two-tier read cache.
  `SyncExposure` is the sync API's record of which documents it has disclosed
  (`KilnCMS.Firing.Sync`).
  """
  use Ash.Domain

  resources do
    resource KilnCMS.Firing.PublishedArtifact do
      define :list_artifacts, action: :read
      define :artifacts_for, action: :for_document, args: [:document_type, :document_id]
      define :get_artifact, action: :get_surface, args: [:document_type, :document_id, :surface]
      define :upsert_artifact, action: :upsert
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
