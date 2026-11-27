defmodule KilnCMS.Forms.Duplicate do
  @moduledoc """
  Duplicating a form (the Forms list's Duplicate button): a full copy of its
  settings and fields, created inactive so it doesn't render publicly under
  its new slug the moment it exists. Its entries stay with the original.

  One transaction (#2717). The copy, each field, the copy's renamed
  autoresponder tokens and its autoresponder switch used to be separate
  commits, so a field that failed halfway left a committed, partial copy
  behind. Now a refused field rolls the whole copy back and the caller learns
  which field it was. A row an older release let through — a dropdown saved
  without options, say — therefore refuses the whole duplicate until it is
  fixed in the original, where it used to be dropped from the copy.

  ## Reserved names

  A field named like the honeypot or `locale` (#2267, #2716) can't be created
  any more, so the copy takes the next free name (`website_2`, `locale_2`) and
  the copy's autoresponder template follows. The renames are returned so the
  caller can say why.

  ## Conditions

  Each field's condition (#2262) is copied, naming the renamed fields by
  their new names. A field whose type this release doesn't know is not
  copied.

  ## The autoresponder

  The copy is created with its autoresponder off, and switched on (when the
  original's is) only once its fields exist: the template's token check reads
  the copy's own fields. A switch that check refuses — the original's template
  names a field it no longer has — is an outcome, not a failure: the copy
  commits with its autoresponder off and the caller is told which tokens are
  unknown. The refusal is a validation error, so Ash returns it before the
  write reaches the database and the transaction carries on.

  The writes run through the `CMS` code interfaces as the acting user, so the
  ordinary policies apply: duplicating is admin-only, like every `Form` write.
  """

  require Logger

  alias Kiln.Tokens
  alias KilnCMS.AfterCommit
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Conditions
  alias KilnCMS.CMS.Form
  alias KilnCMS.CMS.FormField
  alias KilnCMS.Forms
  alias KilnCMS.Forms.Autoresponder
  alias KilnCMS.Forms.Logic

  @typedoc """
  What happened to the copy's autoresponder: `:copied` (on, like the
  original's), `:off_by_default` (the original's is off too), or
  `{:off, tokens}` (the original's is on, but its template names tokens the
  copy doesn't have — empty when the template was refused for being blank).
  """
  @type autoresponder :: :copied | :off_by_default | {:off, [String.t()]}

  @typedoc "A successful duplicate."
  @type result :: %{
          copy: Form.t(),
          renames: [{String.t(), String.t()}],
          autoresponder: autoresponder()
        }

  @doc """
  Duplicate `form` into a new, inactive form.

  `opts` are the usual `:actor` / `:tenant`, plus `:name`, the copy's name
  (default: the original's with ` (copy)` appended; the console passes a
  translated one).

  Returns `{:ok, result}`, `{:error, {:field, name, error}}` when the field
  the original calls `name` couldn't be created (nothing was), or
  `{:error, error}`. A policy refusal or a missing record comes back as is;
  anything else is logged before it is returned, as `CMS.Duplication` does.
  """
  @spec run(Form.t(), keyword()) ::
          {:ok, result()} | {:error, {:field, String.t(), term()}} | {:error, term()}
  def run(%Form{} = form, opts) do
    {name, opts} = Keyword.pop(opts, :name, "#{form.name} (copy)")

    with {:ok, fields} <- CMS.form_fields_for(form.id, opts),
         {:ok, forms} <- CMS.list_forms(opts) do
      attrs =
        Map.merge(copied_settings(form), %{
          name: name,
          slug: unique_slug(form.slug, forms),
          active: false,
          autoresponder_enabled: false
        })

      form |> transact(fields, attrs, with_after_commit_context(opts)) |> log_error(form)
    end
  end

  defp transact(form, fields, attrs, opts) do
    # `Ash.transact/3` turns whatever the function returns as `{:error, _}`
    # into an Ash error class, which would lose *which* field was refused. A
    # refused field leaves the function as a throw instead: the transaction
    # rolls back on it as on any exception, and it is caught just outside.
    AfterCommit.deferring(fn ->
      Ash.transact([Form, FormField], fn -> copy!(form, fields, attrs, opts) end)
    end)
  catch
    {__MODULE__, name, error} -> {:error, {:field, name, error}}
  end

  # The result on success; `{:error, _}` (which rolls the copy back) or a
  # throw from `copy_fields!/3` otherwise.
  defp copy!(form, fields, attrs, opts) do
    with {:ok, copy} <- CMS.create_form(attrs, opts),
         renames = copy_fields!(fields, copy, opts),
         {:ok, copy} <- rename_tokens(form, copy, renames, opts),
         {:ok, copy, autoresponder} <- switch_autoresponder(form, copy, opts) do
      %{copy: copy, renames: renames, autoresponder: autoresponder}
    end
  end

  # Creates each of the original's fields on `copy`, renaming a reserved name
  # to the first free `website_2`, `locale_2`, … Returns the renames made.
  #
  # A field whose type this release doesn't know (a newer release's) is not
  # copied: it couldn't be written back. The others are created in form order
  # and numbered by it, so a condition (#2262) only ever names a field that
  # already exists and comes before it, even when a rename would reorder two
  # fields an older release left at the same position. Each copied condition
  # names the renamed fields by their new names. A condition the copy couldn't
  # apply (it names a field that isn't copied before it, such as one of a type
  # this release doesn't know) is not copied: this release shows that field
  # always anyway, and writing it would refuse the whole duplicate.
  defp copy_fields!(fields, copy, opts) do
    fields = Forms.known_fields(fields)

    renames =
      for field <- fields,
          Forms.reserved_field_name?(field.name),
          do: {field.name, Forms.unique_field_name(field.name, fields)}

    _copied =
      fields
      |> Enum.with_index()
      |> Enum.reduce(MapSet.new(), fn {field, index}, copied ->
        name = List.keyfind(renames, field.name, 0, {nil, field.name}) |> elem(1)

        attrs =
          field
          |> Forms.copyable_field_attrs()
          |> Map.update!(:condition, &rename_references(&1, renames))
          |> Map.merge(%{form_id: copy.id, name: name, position: index})
          |> keep_applicable_condition(field, copied)

        case CMS.create_form_field(attrs, opts) do
          {:ok, _field} -> MapSet.put(copied, name)
          {:error, error} -> throw({__MODULE__, field.name, error})
        end
      end)

    renames
  end

  defp keep_applicable_condition(%{condition: nil} = attrs, _field, _copied), do: attrs

  defp keep_applicable_condition(attrs, field, copied) do
    candidate = %{name: attrs.name, field_type: field.field_type, condition: attrs.condition}

    if Logic.effective(candidate, copied),
      do: attrs,
      else: %{attrs | condition: nil}
  end

  defp rename_references(nil, _renames), do: nil

  defp rename_references(%{rule: rule} = condition, renames) do
    %{
      condition
      | rule:
          Enum.reduce(renames, rule, fn {from, to}, rule -> Conditions.rename(rule, from, to) end)
    }
  end

  # The copy's autoresponder is still off, so only the blank check runs on
  # this write: a template the switch below refuses keeps its renames.
  defp rename_tokens(form, copy, renames, opts) do
    case Autoresponder.rename_field_tokens(form, Map.new(renames)) do
      changes when changes == %{} -> {:ok, copy}
      changes -> CMS.update_form(copy, changes, opts)
    end
  end

  defp switch_autoresponder(%Form{autoresponder_enabled: true}, copy, opts) do
    case CMS.update_form(copy, %{autoresponder_enabled: true}, opts) do
      {:ok, copy} ->
        {:ok, copy, :copied}

      {:error, error} ->
        if template_refusal?(error),
          do: {:ok, copy, {:off, unknown_tokens(copy, opts)}},
          else: {:error, error}
    end
  end

  defp switch_autoresponder(_form, copy, _opts), do: {:ok, copy, :off_by_default}

  # `FormAutoresponderTokens` refusing the switch — the only refusal the copy's
  # own template can earn, and a validation, so nothing reached the database.
  # Anything else is a real failure and rolls the copy back.
  defp template_refusal?(error) do
    case Ash.Error.to_error_class(error) do
      %Ash.Error.Invalid{errors: [_ | _] = errors} ->
        Enum.all?(errors, &(Map.get(&1, :field) in [:autoresponder_subject, :autoresponder_body]))

      _other ->
        false
    end
  end

  defp unknown_tokens(copy, opts) do
    definitions =
      copy.id
      |> CMS.form_fields_for!(opts)
      |> Autoresponder.definitions(copy.name || "", false)

    [copy.autoresponder_subject, copy.autoresponder_body]
    |> Enum.flat_map(fn
      template when is_binary(template) ->
        case Tokens.validate(template, definitions) do
          :ok -> []
          {:error, unknown} -> unknown
        end

      _blank ->
        []
    end)
    |> Enum.uniq()
  end

  defp log_error({:error, %error{}} = result, _form)
       when error in [Ash.Error.Forbidden, Ash.Error.Query.NotFound],
       do: result

  defp log_error({:error, {:field, name, error}} = result, form) do
    Logger.warning(
      "Duplicating form #{form.id} failed on its field #{inspect(name)}: " <>
        Exception.message(Ash.Error.to_error_class(error))
    )

    result
  end

  defp log_error({:error, error} = result, form) do
    Logger.warning(
      "Duplicating form #{form.id} failed: " <>
        Exception.message(Ash.Error.to_error_class(error))
    )

    result
  end

  defp log_error(result, _form), do: result

  # Every attribute the create action accepts, read off the resource rather than
  # listed here. The hand-written list this replaced had already drifted — the
  # three autoresponder fields were never copied — and since #648 a missed
  # attribute is a security default rather than a cosmetic one: a copy that
  # lost `embed_origins` silently falls back to the deployment-wide allowlist,
  # which on a multi-org instance is every other org's embedders.
  defp copied_settings(form) do
    Form
    |> Ash.Resource.Info.action(:create)
    |> Map.fetch!(:accept)
    |> Map.new(&{&1, Map.get(form, &1)})
  end

  # A slug no form of this site has yet: `contact-copy`, `contact-copy-2`, …
  defp unique_slug(slug, forms) do
    taken = MapSet.new(forms, & &1.slug)
    base = "#{slug}-copy"

    [base | Enum.map(2..1000, &"#{base}-#{&1}")]
    |> Enum.find(&(!MapSet.member?(taken, &1)))
  end

  # Only inside `AfterCommit.deferring/1`: `BustFormCache` goes through
  # `AfterCommit.run/1`, so silencing Ash's nested-hook warning is sound.
  defp with_after_commit_context(opts),
    do:
      Keyword.update(opts, :context, AfterCommit.context(), &Map.merge(&1, AfterCommit.context()))
end
