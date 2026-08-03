defmodule KilnCMS.CMS.Changes.EnqueueOEmbed do
  @moduledoc """
  After a content create/update, enqueue `KilnCMS.OEmbed.ResolveWorker` when the
  document holds an embed block whose metadata is missing for its current URL
  (#489).

  ## Why a worker and not the save

  Resolving means an outbound HTTP request. Doing it inside the save makes an
  editor's "Save" wait on a third party — and a provider having a bad afternoon
  becomes Kiln having a bad afternoon, on the one action that must not fail.
  Enqueuing costs a row; the metadata lands a moment later and the editor sees
  it on the next load.

  It also keeps the failure mode right: an embed whose metadata never resolves
  renders the bare-URL figure it always did. Nothing here can fail a save.

  ## Only when there is something to do

  The check is deliberately narrow — a job is enqueued only if some embed block
  has a URL a provider claims *and* metadata that does not already describe that
  URL (`KilnCMS.Blocks.Embed.fresh?/1`). Without that, every
  save of every document with an embed would enqueue a job that re-fetches
  metadata it already has, which is a lot of outbound traffic to buy nothing.

  That also makes it self-limiting on the way back: the worker writes
  `resolved_url`, so a document that resolved does not enqueue again — and an
  edit that changes the URL makes it stale again, which is the point. Re-resolution for
  staleness is a separate, deliberate act — see the worker.
  """
  use Ash.Resource.Change

  alias KilnCMS.Blocks.Embed
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.OEmbed
  alias KilnCMS.OEmbed.ResolveWorker

  @impl true
  def change(changeset, _opts, _context) do
    if OEmbed.enabled?() do
      Ash.Changeset.after_action(changeset, &enqueue/2)
    else
      changeset
    end
  end

  defp enqueue(_changeset, %resource{id: id, org_id: org_id} = record) do
    if needs_resolution?(record) do
      %{"org_id" => org_id, "resource" => to_string(resource), "id" => id}
      |> ResolveWorker.new()
      |> Oban.insert!()
    end

    {:ok, record}
  end

  defp needs_resolution?(record) do
    record
    |> Map.get(:blocks)
    |> TypedBlocks.to_typed()
    |> Enum.any?(fn
      # `fresh?/1`, not "has a title": an editor who pastes a different link
      # into an existing block keeps the old title, so a blank-title check
      # would never re-resolve and the first target's card would sit over the
      # second one's href forever.
      %Embed{} = block -> OEmbed.resolvable?(block.url) and not Embed.fresh?(block)
      _other -> false
    end)
  end
end
