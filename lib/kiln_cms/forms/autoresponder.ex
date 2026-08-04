defmodule KilnCMS.Forms.Autoresponder do
  @moduledoc """
  The confirmation email a form can send back to its **submitter** — separate
  from `Form.notify_email` (the admin copy `KilnCMS.Forms.NotificationWorker`
  sends). `docs/form-builder-plan.md`'s Phase 6, built here as part of #468's
  token-system generalization: subject/body are `Kiln.Tokens` patterns using
  the same `[token]` bracket syntax the slug engine uses, not the plan doc's
  original `{{field}}` mustache — one substitution syntax across the app,
  not two.

  Only ever fires when the form actually has an `:email`-typed `FormField`
  *and* the submission gave it a non-blank value — `eligible?/3` is the one
  place that decides "is there anyone to confirm with", so
  `KilnCMS.Forms.record/3` and the config-time validation
  (`KilnCMS.CMS.Validations.FormAutoresponderTokens`) can't drift on it.
  """

  alias KilnCMS.CMS

  @type field :: KilnCMS.CMS.FormField.t()

  @doc """
  Token definitions for `fields` — `[field:<name>]` per declared field plus
  `[form-name]`. `escape?` HTML-escapes every resolved value (for the email
  body); the subject line is a mail header, never HTML, so callers building
  it pass `escape?: false` — but a mail header still can't tolerate a raw
  CR/LF (an anonymous submitter's field value could otherwise smuggle extra
  headers into the subject), so that path strips line breaks instead.
  """
  @spec definitions([field()], String.t(), boolean()) :: [Kiln.Tokens.definition()]
  def definitions(fields, form_name, escape?) do
    wrap = if escape?, do: &h/1, else: &plain/1

    field_definitions =
      Enum.map(fields, fn field ->
        %{
          match: "field:#{field.name}",
          resolve: fn _token, data -> data |> Map.get(field.name) |> wrap.() end
        }
      end)

    [%{match: "form-name", resolve: fn _token, _data -> wrap.(form_name) end} | field_definitions]
  end

  @doc """
  Token definitions for a form by id — looks its current fields up
  (`authorize?: false`: this runs from a validation or the anonymous
  submission pipeline, neither of which carries an editor session).  A `nil`
  id (a brand-new, not-yet-persisted form) has no fields yet.
  """
  @spec definitions_for_form(Ecto.UUID.t() | nil, String.t(), boolean(), Ash.ToTenant.t()) ::
          [Kiln.Tokens.definition()]
  def definitions_for_form(nil, form_name, escape?, _tenant),
    do: definitions([], form_name, escape?)

  def definitions_for_form(form_id, form_name, escape?, tenant) do
    fields = CMS.form_fields_for!(form_id, authorize?: false, tenant: tenant)
    definitions(fields, form_name, escape?)
  end

  @doc """
  Whether `form` should autorespond to a submission of `data`, and the
  address to send it to. `false` covers every reason it shouldn't: the
  toggle is off, the form declares no `:email` field, or this particular
  submission left that field blank (an optional email field, unfilled).
  """
  @spec eligible?(KilnCMS.CMS.Form.t(), map(), [field()]) :: {true, String.t()} | false
  def eligible?(form, data, fields) do
    with true <- form.autoresponder_enabled,
         %{name: name} <- Enum.find(fields, &(&1.field_type == :email)),
         value when is_binary(value) and value != "" <- Map.get(data, name) do
      {true, value}
    else
      _ -> false
    end
  end

  @doc "Expand `form`'s configured subject/body against a submission's `data`."
  @spec render(KilnCMS.CMS.Form.t(), [field()], map()) :: {String.t(), String.t()}
  def render(form, fields, data) do
    subject =
      Kiln.Tokens.expand(form.autoresponder_subject, definitions(fields, form.name, false), data)

    body = Kiln.Tokens.expand(form.autoresponder_body, definitions(fields, form.name, true), data)
    {subject, body}
  end

  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  defp plain(value), do: value |> to_string() |> String.replace(~r/[\r\n]+/, " ")
end
