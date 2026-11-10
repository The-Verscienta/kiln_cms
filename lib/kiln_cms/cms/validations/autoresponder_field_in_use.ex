defmodule KilnCMS.CMS.Validations.AutoresponderFieldInUse do
  @moduledoc """
  Refuses to take a `FormField` away from its form while that form's
  autoresponder is on and its subject or body uses the field's
  `[field:<name>]` token (#2343) — deleting the field, or moving it to another
  form by changing `form_id`. Either would leave every confirmation from then
  on rendering that token as `""`.

  A disabled autoresponder does not hold the field: nothing renders it, and
  `FormAutoresponderTokens` checks the template again when it is switched back
  on. A rename is not refused; `RewriteAutoresponderTokens` carries the
  template along instead.

  The form is read as the acting user with the caller's tenant and
  authorization; a read that fails refuses the write rather than skip the check.
  """
  use Ash.Resource.Validation

  alias KilnCMS.CMS

  @impl true
  def validate(changeset, _opts, context) do
    if leaves_form?(changeset) do
      opts =
        context
        |> Ash.Context.to_opts()
        |> Keyword.put(:tenant, changeset.to_tenant)

      field = changeset.data

      case CMS.get_form(field.form_id, opts) do
        {:ok, form} -> check(form, field, changeset.action_type)
        {:error, error} -> {:error, error}
      end
    else
      :ok
    end
  end

  defp leaves_form?(%{action_type: :destroy}), do: true

  defp leaves_form?(%{action_type: :update} = changeset),
    do: Ash.Changeset.changing_attribute?(changeset, :form_id)

  defp leaves_form?(_changeset), do: false

  defp check(%{autoresponder_enabled: true} = form, field, action_type) do
    token = "[field:#{field.name}]"

    if Enum.any?([form.autoresponder_subject, form.autoresponder_body], &uses?(&1, token)) do
      {:error, error_opts(action_type, token)}
    else
      :ok
    end
  end

  defp check(_form, _field, _action_type), do: :ok

  defp uses?(value, token) when is_binary(value), do: String.contains?(value, token)
  defp uses?(_value, _token), do: false

  defp error_opts(:update, token) do
    [
      field: :form_id,
      message: "the autoresponder uses #{token}: remove it from the Confirmations template first"
    ]
  end

  defp error_opts(_destroy, token) do
    [message: "The autoresponder uses #{token}: remove it from the Confirmations template first."]
  end
end
