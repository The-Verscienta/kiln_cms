defmodule KilnCMS.CMS.Checks.EditorMayPublish do
  @moduledoc """
  Matches an **editor** of the request's org when that site lets editors
  publish (`KilnCMS.CMS.SiteEditorialSettings.editors_can_publish`).

  Sits beside `OrgAdmin` on `:publish` / `:publish_scheduled`, so an admin
  never depends on the setting and an editor depends on nothing else. The tier
  and the setting are resolved on the same org (`Scoping.subject_org_id/1`), and
  the setting is read uncached through `KilnCMS.CMS.EditorialSettings`, which
  fails closed — this runs inside the publish transaction.

  Matches no struct (a bare module is at most a runtime dependency): a check
  that pattern-matched the content resource's struct would be a compile-time
  cycle with the `policies` block that names it.
  """
  use Ash.Policy.SimpleCheck

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.EditorialSettings

  @impl Ash.Policy.Check
  def describe(_opts),
    do: "an editor of the request's organization, on a site that lets editors publish"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, %{subject: subject}, _opts) do
    Scoping.effective_tier(actor, subject) == :editor and
      EditorialSettings.editors_can_publish?(Scoping.subject_org_id(subject))
  end
end
