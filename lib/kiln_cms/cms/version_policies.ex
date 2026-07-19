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
      actions do
        destroy :destroy
      end

      policies do
        bypass actor_attribute_equals(:role, :admin) do
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
