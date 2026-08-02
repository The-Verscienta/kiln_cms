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
      postgres do
        custom_indexes do
          index [:version_source_id, :version_inserted_at, :id]
        end
      end

      actions do
        destroy :destroy
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
