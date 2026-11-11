defmodule KilnCMS.CMS.VersionPolicies do
  @moduledoc """
  Shared Ash policies (and a system-only destroy action) for AshPaperTrail
  version resources.

  Mixed into `Page.Version` and `Post.Version` via the `paper_trail` `mixin`
  option. Version history is editorial/audit data — editors and admins only;
  anonymous users and viewers must not read draft snapshots from `changes`.

  The injected `:destroy` action exists solely for
  `KilnCMS.CMS.Changes.CoalesceAutosaveVersions` to prune superseded autosave
  snapshots; it's forbidden to every actor by the destroy policy below and only
  runs as a trusted system caller (`authorize?: false`).
  """

  def policies do
    quote do
      # Every read of a document's history filters on `version_source_id` and
      # orders by `(version_inserted_at, id)` — the governance chain's fold and
      # its keyset resume (#598), the governance trail, autosave coalescing on
      # every debounced save, and the version-history UI. Declared here rather
      # than per resource because AshPaperTrail generates the version resource's
      # `postgres` block itself, and this mixin is the seam it leaves open.
      #
      # `pages_versions` and `posts_versions` got a single-column
      # `version_source_id` index when their FKs were dropped
      # (`20260622205523_drop_version_source_fks`); `entries_versions` — the
      # table every DYNAMIC content type shares — got neither, so those reads
      # were sequential scans over every version of every entry in the
      # deployment (#672). The composite covers the sort as well as the filter,
      # and supersedes the single-column pair.
      #
      # The second index serves the one read that starts from a TIME rather
      # than a document: the sync API's "which documents changed in this
      # window" (`KilnCMS.Firing.Sync`). Without it that question is a scan of
      # every version the org has ever written, on every poll. (Tenant-scoped
      # like the first, so both lead with `org_id`.)
      #
      # The third is partial, for the change-severity read-back
      # (`KilnCMS.CMS.LatestEdit`): it only ever wants rows that carry a
      # `change_severity`, which is a small minority, so without it a document
      # with none walks its whole version history. Postgres scans it backwards
      # for the `desc` order. Built concurrently: the version tables are the
      # largest in the schema, and a plain build blocks their writes.
      postgres do
        custom_indexes do
          index [:version_source_id, :version_inserted_at, :id]
          index [:version_inserted_at]

          index [:version_source_id, :version_inserted_at, :id],
            where: "change_severity IS NOT NULL",
            concurrently: true,
            # Named per resource: the default name is the plain composite's.
            name:
              "#{__MODULE__ |> Module.split() |> Enum.at(-2) |> Macro.underscore()}_change_severity_edits_index"
        end
      end

      actions do
        destroy :destroy
      end

      # The row's own signature (#598/#670). It is what lets `Chain.verify/4`
      # tell a version that ARRIVED LATE from one SPLICED IN once the fold order
      # is assigned rather than re-derived: a late row carries a valid one, a row
      # somebody inserted into the table does not.
      #
      # Declared in this mixin rather than per resource because AshPaperTrail
      # generates the version resource itself, and this is the seam it leaves
      # open — so `Page.Version`, `Post.Version`, `Entry.Version` and every
      # overlay tier get it without a per-resource edit.
      #
      # `nil` on a deployment with no provenance key, which is the normal state
      # of a default install and reported as an anomaly rather than a verdict.
      attributes do
        attribute :chain_signature, :string, public?: false
        attribute :chain_key_id, :string, public?: false
      end

      changes do
        change KilnCMS.Governance.Changes.SignVersion, on: [:create]
      end

      # An editor's read restriction (#2281) hides private custom fields from
      # a version's `changes` too.
      preparations do
        prepare KilnCMS.CMS.Preparations.MaskVersionFields
      end

      policies do
        bypass KilnCMS.CMS.Checks.OrgAdmin do
          authorize_if always()
        end

        # A version's `changes` carry the full document snapshot, so history
        # follows the SAME editorial read scope as the document (#332 slice 2):
        # the check resolves a version twin to its source type. Without this an
        # out-of-scope draft would leak through its history.
        policy action_type(:read) do
          authorize_if KilnCMS.CMS.Checks.ReadableContentType

          # A `:draft_write` key (#2273) reads the history of its own drafts
          # only (autosave coalescing reads it as the saving actor).
          authorize_if KilnCMS.Accounts.Checks.DraftWriteOwnDrafts
        end

        # Version rows are created by AshPaperTrail (authorize?: false); manual
        # create/update is denied when authorization is in effect.
        policy action_type([:create, :update]) do
          forbid_if always()
        end

        policy action_type(:destroy) do
          forbid_if always()
        end
      end
    end
  end
end
