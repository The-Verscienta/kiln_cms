defmodule KilnCMS.CMS.SettingsVersionPolicies do
  @moduledoc """
  Shared Ash policies for the version resource of an **admin settings**
  resource, mixed in via AshPaperTrail's `mixin` option.

  Distinct from `KilnCMS.CMS.VersionPolicies`, which serves *content* version
  twins: those carry editorial snapshots that editors legitimately read, and
  they need the `version_source_id` index and the coalescing destroy action.
  This one carries "who changed a setting, and to what", which is an
  administrative record — org admin only, and nothing may destroy it.

  The source resource may well be publicly readable (`SiteCodeInjection` is: its
  contents are served to anonymous visitors). Its *history* is not, and the
  distinction is the point — "what is on the site now" and "who put it there,
  and what it said last week" are different questions with different audiences.
  """

  def policies do
    quote do
      policies do
        policy action_type(:read) do
          authorize_if KilnCMS.CMS.Checks.OrgAdmin
        end

        # Versions are written by AshPaperTrail inside the source action's own
        # transaction, as the system. Nothing else creates them, and nothing at
        # all destroys them — an audit row that an admin can delete answers the
        # question it exists for only when nobody minds the answer.
        policy action_type([:create, :update, :destroy]) do
          forbid_if always()
        end
      end
    end
  end
end
