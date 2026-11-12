defmodule KilnCMS.CMS.Changes.RewriteAutoresponderTokens do
  @moduledoc """
  A `FormField` rename carries its form's autoresponder template along (#2343):
  every `[field:<old>]` in `Form.autoresponder_subject`/`.autoresponder_body`
  becomes `[field:<new>]`, in the rename's own transaction — so no submission
  between the two writes renders the old token as `""`, and a refused form
  write refuses the rename.

  The replace is of the whole bracketed token, so renaming `email` leaves
  `[field:email2]` alone. A disabled template is kept in step too: switching
  it back on later must not find a token for a field that was only renamed.

  The form write skips `FormAutoresponderTokens`' token check
  (`autoresponder_token_rename: true` in the changeset context): it maps one
  token the template already held to the field's new name, so it cannot add an
  unknown one — while a template that already holds a stale token from an
  earlier delete would otherwise refuse this rename over a field the admin is
  not editing.

  Runs as the renaming actor with the caller's tenant and authorization
  (`FormField` writes are admin-only, as are `Form` writes). A move to another
  form (`form_id` changing) rewrites nothing; `AutoresponderFieldInUse`
  refuses that move while the old form's enabled template still uses the field.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS
  alias KilnCMS.Forms.Autoresponder

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, &rewrite(&1, &2, context))
  end

  defp rewrite(changeset, field, context) do
    from = changeset.data.name

    if from == field.name or changeset.data.form_id != field.form_id do
      {:ok, field}
    else
      # Inside the rename's own transaction, on purpose (see the moduledoc).
      opts =
        context
        |> Ash.Context.to_opts()
        |> Keyword.put(:tenant, changeset.to_tenant)
        |> Keyword.put(:context, %{
          autoresponder_token_rename: true,
          warn_on_transaction_hooks?: false
        })

      with {:ok, form} <- CMS.get_form(field.form_id, opts),
           changes = Autoresponder.rename_field_tokens(form, %{from => field.name}),
           {:ok, _form} <- write(form, changes, opts) do
        {:ok, field}
      end
    end
  end

  # Nothing to carry over: no write, so the form's `updated_at` stays put.
  defp write(form, changes, _opts) when changes == %{}, do: {:ok, form}
  defp write(form, changes, opts), do: CMS.update_form(form, changes, opts)
end
