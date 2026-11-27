defmodule KilnCMS.CMS.Changes.RewriteConditionReferences do
  @moduledoc """
  A `FormField` rename carries the conditions that name it along (#2262):
  every other field of the form whose `condition` names the old name is
  rewritten to the new one (`KilnCMS.CMS.Conditions.rename/3`), in the
  rename's own transaction. No submission between the two writes sees a rule
  naming a field that is gone (which would leave its field shown), and a
  refused rewrite refuses the rename.

  The rewritten rule names a field that already existed, earlier in the form
  (`KilnCMS.CMS.Validations.FormFieldCondition` checked the rename's order),
  so only the rule changes. Runs as the renaming actor with the caller's
  tenant and authorization (`FormField` writes are admin-only). A move to
  another form rewrites nothing: the validation refuses it while any field
  names this one.

  The rewritten fields' names are put in the renamed field's metadata as
  `:condition_rewrites` (their labels, in form order), so the builder can say
  whose conditions it changed.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Conditions
  alias KilnCMS.Forms.Logic

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
        |> Keyword.put(:context, %{warn_on_transaction_hooks?: false})

      with {:ok, fields} <-
             CMS.form_fields_for(field.form_id, Keyword.put(opts, :authorize_with, :error)),
           {:ok, rewritten} <- rewrite_all(fields, field, from, opts) do
        {:ok, Ash.Resource.put_metadata(field, :condition_rewrites, rewritten)}
      end
    end
  end

  defp rewrite_all(fields, renamed, from, opts) do
    fields
    # A row of a type this release doesn't know is left alone: it couldn't be
    # written back, and this release never applies its condition.
    |> Enum.reject(&(&1.id == renamed.id or not Logic.known?(&1)))
    |> Enum.reduce_while({:ok, []}, fn other, {:ok, done} ->
      case rewrite_one(other, renamed, from, opts) do
        :unchanged -> {:cont, {:ok, done}}
        :ok -> {:cont, {:ok, [other.label || other.name | done]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  # A condition whose action this release doesn't know is left as it is: it
  # couldn't be written back, and its field is shown anyway.
  defp rewrite_one(other, renamed, from, opts) do
    with %{action: action, rule: rule} when action in [:show, :hide] <- Logic.stored(other),
         true <- from in Conditions.references(rule) do
      condition = %{action: action, rule: Conditions.rename(rule, from, renamed.name)}

      case CMS.update_form_field(other, %{condition: condition}, opts) do
        {:ok, _other} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      _none -> :unchanged
    end
  end
end
