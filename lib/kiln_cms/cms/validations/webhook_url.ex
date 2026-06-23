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
            {:error,
             InvalidAttribute.exception(
               field: :url,
               message: message,
               value: url
             )}
        end

      _ ->
        :ok
    end
  end
end
