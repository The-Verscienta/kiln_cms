defmodule KilnCMS.CMS.Validations.WebhookUrl do
  @moduledoc false
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias KilnCMS.Webhooks.SafeUrl

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :url) do
      url when is_binary(url) ->
        case SafeUrl.validate(url) do
          :ok ->
            :ok

          {:error, message} ->
            # No `value:` (#2245): the error is logged and reported, and the
            # URL may be the credential.
            {:error, InvalidAttribute.exception(field: :url, message: message)}
        end

      _ ->
        :ok
    end
  end
end
