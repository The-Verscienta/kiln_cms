defmodule KilnCMS.CMS.VersionPolicies do
  @moduledoc """
  Shared Ash policies for AshPaperTrail version resources.

  Mixed into `Page.Version` and `Post.Version` via the `paper_trail` `mixin`
  option. Version history is editorial/audit data — editors and admins only;
  anonymous users and viewers must not read draft snapshots from `changes`.
  """

  def policies do
    quote do
      policies do
        bypass actor_attribute_equals(:role, :admin) do
          authorize_if always()
        end

        policy action_type(:read) do
          authorize_if actor_attribute_equals(:role, :editor)
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
