defmodule KilnCMS.CMS.Validations.ReleaseWithinSizeLimit do
  @moduledoc """
  Refuses to add an item to a release that has reached its size cap (#837).

  A release's whole guarantee is that it goes live inside **one**
  `Repo.transaction`, which is also its cost: that transaction holds row locks on
  every item for its duration, and the console recomputes readiness over every
  item on each render. Both scale with item count, and neither had a ceiling —
  so a release built by a bulk "select all" could hold locks until
  `KilnCMS.CMS.Releases.transaction_timeout_ms/0` aborted it, *after* the wait.

  The cap is a guardrail, not an invariant. It is checked with a count, so two
  concurrent adds at `cap - 1` can both pass and overshoot by one; that is fine,
  because nothing downstream depends on the exact number. What matters is that a
  release cannot grow unboundedly by accident.

  Configure it per install (see `KilnCMS.CMS.Releases.max_items/0`):

      config :kiln_cms, KilnCMS.CMS.Releases, max_items: 500
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges
  alias KilnCMS.CMS.Releases

  @impl true
  def validate(changeset, _opts, _context) do
    release_id = Ash.Changeset.get_attribute(changeset, :release_id)
    cap = Releases.max_items()

    if is_nil(release_id) or pending_count(release_id, changeset.tenant) < cap do
      :ok
    else
      {:error,
       InvalidChanges.exception(
         fields: [:release_id],
         message: "release is full (#{cap} items); ship or split it"
       )}
    end
  end

  defp pending_count(release_id, tenant) do
    case KilnCMS.CMS.list_release_items_with_status(release_id, :pending,
           authorize?: false,
           tenant: tenant
         ) do
      {:ok, items} -> length(items)
      # Unreadable for any reason: don't invent a cap failure out of a read
      # problem — the add's other validations and the FK will speak for it.
      _ -> 0
    end
  end
end
