defmodule KilnCMS.CMS.Validations.PrivateBucketAdded do
  @moduledoc """
  A storage profile's private bucket can be added where there was none, and
  never changed or removed in place (`KilnCMS.CMS.StorageProfile`).

  Gated documents already in the private bucket are read through the profile,
  so pointing the profile at another private bucket would strand them exactly
  as moving the public bucket would. `Changes.SaveStorageProfile` creates a new
  profile for that instead; this is the guard that keeps the in-place update
  honest if anything else ever calls it.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    old = changeset.data.private_bucket
    new = Ash.Changeset.get_attribute(changeset, :private_bucket)

    if is_nil(old) or old == new do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :private_bucket,
         message: "can't be changed once set; files already in it would be left behind"
       )}
    end
  end
end
