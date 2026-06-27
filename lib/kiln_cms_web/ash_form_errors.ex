defmodule KilnCMSWeb.AshFormErrors do
  @moduledoc """
  Custom error translations for Ash errors in Phoenix forms (e.g. for optimistic
  locking conflicts). This prevents "unhandled error" warnings and gives users
  actionable messages.
  """

  defimpl AshPhoenix.FormData.Error, for: Ash.Error.Changes.StaleRecord do
    def to_form_error(_error) do
      {:form, "This record was updated by someone else. Please reload and try again.", []}
    end
  end
end
