defmodule KilnCMS.CMS.Validations.RequiredConsent do
  @moduledoc """
  Blocks publishing content that is missing a required editorial consent
  (compliance cluster, #356).

  Config-gated and **off by default** — a deployment lists the consent kinds
  every publish must have:

      config :kiln_cms, :consent, required_before_publish: [:reviewer_signoff]

  With an empty/absent list the validation is a no-op, so existing publishing is
  unchanged. When configured, `:publish` / `:publish_scheduled` fail unless a
  `KilnCMS.CMS.Consent` of each required kind is already linked to the document —
  making "cleared to publish, approved by X on date Y" enforceable, not just
  documentary.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case required_kinds() do
      [] ->
        :ok

      required ->
        missing = required -- present_kinds(changeset.data)

        if missing == [] do
          :ok
        else
          {:error,
           field: :state,
           message:
             "cannot publish without consent: #{Enum.map_join(missing, ", ", &to_string/1)}"}
        end
    end
  end

  defp required_kinds do
    :kiln_cms |> Application.get_env(:consent, []) |> Keyword.get(:required_before_publish, [])
  end

  # Consent kinds already recorded for this document. Read as the system — the
  # gate must see every consent regardless of the publishing actor.
  defp present_kinds(document) do
    type = to_string(KilnCMS.Firing.Engine.document_type(document))

    KilnCMS.CMS.list_consents_for!(type, document.id, authorize?: false)
    |> Enum.map(& &1.kind)
    |> Enum.uniq()
  end
end
