defmodule KilnCMS.CMS.Checks.MediaInAudience do
  @moduledoc """
  Authorizes a gated `MediaItem` (#481) whose `audience` the actor holds **on
  the request's organization** — the `KilnCMS.CMS.Checks.InAudience` shape
  for media instead of published content.

  Not the same check: `InAudience`'s expression also requires
  `state == :published`, and `MediaItem` has no publish workflow — it's
  metadata for a stored blob, gated purely on `audience`. Resolution goes
  through the same `KilnCMS.Accounts.Scoping.audiences/2` (per-org
  membership, fail-closed for a foreign org) so a media gate and a content
  gate never disagree about what audience a reader holds.
  """
  use Ash.Policy.FilterCheck

  alias KilnCMS.Accounts.Scoping

  @impl true
  def describe(_opts), do: "media whose audience the actor holds on this org"

  @impl true
  def filter(actor, context, _opts) do
    case Scoping.audiences(actor, Map.get(context, :subject)) do
      [] -> false
      # Never a quarantined item (#1122): the audience-holder would otherwise
      # be able to reach the unstripped private blob through the download
      # controller before the strip ran.
      audiences -> expr(audience in ^audiences and quarantined == false)
    end
  end
end
