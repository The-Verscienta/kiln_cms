defmodule KilnCMS.CMS.Validations.ReleaseWithinSizeLimit do
  @moduledoc """
  Refuses to add an item to a release that has reached its size cap (#837).

  A release's whole guarantee is that it goes live inside **one**
  `Repo.transaction`, which is also its cost: that transaction holds row locks on
  every item for its duration, and the console recomputes readiness over every
  item on each render. Both scale with item count, and neither had a ceiling —
  so a release built by a bulk "select all" could hold locks until
  `KilnCMS.CMS.Releases.transaction_timeout_ms/0` aborted it, *after* the wait.

  ## The cap is exact (#3073)

  `:add` runs this with `before_action?: true`, declared after
  `KilnCMS.CMS.Validations.ReleaseOpenForEdit`, so the count runs inside the
  add's own transaction, after that validation has locked the release row
  `FOR UPDATE`. Adds to one release therefore take turns, and each counts
  with every earlier add committed: two adds at `cap - 1` no longer both pass.
  (Counted at changeset build, as it used to be, both could, and the release
  overshot by one.)

  It must not lock the release itself. A second lock on the row after the
  first would be an upgrade if the first were ever `FOR SHARE`, and two adds
  holding the share lock would deadlock on each other's upgrade. The lock
  order and the cost of serializing adds are in `ReleaseOpenForEdit`'s
  moduledoc. The count reads every pending item of the release, under the
  lock; the cap keeps that at most `cap` rows unless it was lowered after the
  release filled.

  Configure it per install (see `KilnCMS.CMS.Releases.max_items/0`):

      config :kiln_cms, KilnCMS.CMS.Releases, max_items: 500
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidChanges
  alias KilnCMS.CMS.Releases
  alias KilnCMS.CMS.Validations.Lookup

  @impl true
  def validate(changeset, _opts, context) do
    release_id = Ash.Changeset.get_attribute(changeset, :release_id)
    cap = Releases.max_items()

    case release_id && pending_count(release_id, changeset.tenant, context) do
      nil ->
        :ok

      {:ok, count} when count < cap ->
        :ok

      {:ok, _count} ->
        {:error,
         InvalidChanges.exception(
           fields: [:release_id],
           message: gettext("release is full (%{cap} items); ship or split it", cap: cap)
         )}

      {:error, %Ash.Error.Forbidden{} = forbidden} ->
        {:error, forbidden}

      {:error, _error} ->
        {:error,
         InvalidChanges.exception(
           fields: [:release_id],
           message: gettext("release size could not be checked")
         )}
    end
  end

  # As the caller (#1659), with `authorize_with: :error`. The count IS the cap,
  # so a read that came back short would let the release grow past it: a
  # refused or failed read is a rejection, never a count of zero. (It used to
  # be zero, which let an unreadable release take any number of items.)
  defp pending_count(release_id, tenant, context) do
    case KilnCMS.CMS.list_release_items_with_status(
           release_id,
           :pending,
           Lookup.as_caller(context, tenant)
         ) do
      {:ok, items} -> {:ok, length(items)}
      {:error, error} -> {:error, error}
    end
  end
end
