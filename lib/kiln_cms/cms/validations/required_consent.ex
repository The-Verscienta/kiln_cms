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

  alias KilnCMS.CMS.Validations.Lookup

  @impl true
  def validate(changeset, _opts, _context) do
    case required_kinds() do
      [] -> :ok
      required -> check(required, changeset.data)
    end
  end

  defp check(required, document) do
    case present_kinds(document) do
      {:ok, present} ->
        case required -- present do
          [] ->
            :ok

          missing ->
            {:error,
             field: :state,
             message:
               "cannot publish without consent: #{Enum.map_join(missing, ", ", &to_string/1)}"}
        end

      # Fail closed: a refused read is not "no consent required", and it is not
      # "every consent present" either. The publish is refused.
      {:error, _error} ->
        {:error, field: :state, message: "cannot publish: consents could not be checked"}
    end
  end

  defp required_kinds do
    :kiln_cms |> Application.get_env(:consent, []) |> Keyword.get(:required_before_publish, [])
  end

  # Consent kinds already recorded for this document. Read as the system actor
  # (#1659), not the caller: `:publish_scheduled` is run by the AshOban
  # scheduler, which has no actor and could not read a consent, and the gate
  # must see every consent whoever publishes. Admitted to `for_content` only
  # (`CMS.Consent`'s policy). Scoped to the document's own site (epic #336) so
  # a consent on another org's content can never satisfy this org's gate.
  defp present_kinds(document) do
    type = to_string(KilnCMS.Firing.Engine.document_type(document))

    case KilnCMS.CMS.list_consents_for(type, document.id,
           actor: Lookup.system(),
           authorize_with: :error,
           tenant: document.org_id
         ) do
      {:ok, consents} -> {:ok, consents |> Enum.map(& &1.kind) |> Enum.uniq()}
      {:error, error} -> {:error, error}
    end
  end
end
