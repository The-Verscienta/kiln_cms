defmodule KilnCMS.CMS.Validations.FormAutoresponderTokens do
  @moduledoc """
  Config-time enforcement for `Form.autoresponder_subject`/`.autoresponder_body`
  (#468): both must use only `Kiln.Tokens` known to this form (its own
  `[field:<name>]`s, plus `[form-name]`), and — the same "keep the existing
  validation approach" the slug pattern engine already follows — both must be
  non-blank while `autoresponder_enabled` is true. Disabled, they may be
  blank or even reference a token that no longer exists; nothing renders them.

  Only runs when this changeset actually touches one of the three
  autoresponder attributes. Without that guard, saving an unrelated tab
  (General, Fields) would re-validate a template against whatever the form's
  fields look like *right now* — and a template written against a field an
  admin has since deleted would then block that unrelated save with an error
  about a field the admin isn't even looking at.
  """
  use Ash.Resource.Validation

  alias Kiln.Tokens
  alias KilnCMS.Forms.Autoresponder

  @impl true
  def validate(changeset, _opts, _context) do
    if touches_autoresponder?(changeset) do
      enabled? = Ash.Changeset.get_attribute(changeset, :autoresponder_enabled)
      subject = Ash.Changeset.get_attribute(changeset, :autoresponder_subject)
      body = Ash.Changeset.get_attribute(changeset, :autoresponder_body)

      definitions =
        Autoresponder.definitions_for_form(
          changeset.data.id,
          Ash.Changeset.get_attribute(changeset, :name) || "",
          false,
          changeset.tenant
        )

      with :ok <- check_blank(:autoresponder_subject, subject, enabled?),
           :ok <- check_blank(:autoresponder_body, body, enabled?),
           :ok <- check_tokens(:autoresponder_subject, subject, definitions, enabled?) do
        check_tokens(:autoresponder_body, body, definitions, enabled?)
      end
    else
      :ok
    end
  end

  defp touches_autoresponder?(changeset) do
    Enum.any?(
      [:autoresponder_enabled, :autoresponder_subject, :autoresponder_body],
      &Ash.Changeset.changing_attribute?(changeset, &1)
    )
  end

  defp check_blank(field, value, true) when value in [nil, ""] do
    {:error, field: field, message: "can't be blank while the autoresponder is on"}
  end

  defp check_blank(_field, _value, _enabled?), do: :ok

  defp check_tokens(_field, _value, _definitions, false), do: :ok
  defp check_tokens(_field, nil, _definitions, true), do: :ok

  defp check_tokens(field, value, definitions, true) do
    case Tokens.validate(value, definitions) do
      :ok ->
        :ok

      {:error, unknown} ->
        {:error,
         field: field,
         message:
           "unknown token(s) #{Enum.map_join(unknown, ", ", &"[#{&1}]")} — supported: " <>
             Enum.map_join(Tokens.names(definitions), ", ", &"[#{&1}]")}
    end
  end
end
