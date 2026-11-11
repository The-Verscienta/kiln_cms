defmodule KilnCMS.CMS.Validations.AdminIdleTimeoutNotLonger do
  @moduledoc """
  A site's administrators may not be given a longer idle timeout than everyone
  else (#2246): `admin_idle_timeout_minutes` exists to be the stricter of the
  two. When only one is set there is nothing to compare.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def validate(changeset, _opts, _context) do
    general = Ash.Changeset.get_attribute(changeset, :idle_timeout_minutes)
    admin = Ash.Changeset.get_attribute(changeset, :admin_idle_timeout_minutes)

    if is_integer(general) and is_integer(admin) and admin > general do
      {:error,
       InvalidAttribute.exception(
         field: :admin_idle_timeout_minutes,
         message: "must not be longer than the timeout for everyone"
       )}
    else
      :ok
    end
  end
end
