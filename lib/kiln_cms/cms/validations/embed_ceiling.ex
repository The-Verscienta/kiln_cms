defmodule KilnCMS.CMS.Validations.EmbedCeiling do
  @moduledoc """
  Refuses a tenant-written framing allowlist that reaches outside the
  operator's ceiling (#1133) — on `Form.embed_origins` and
  `SiteEmbedSettings.embed_origins`, the two rungs a tenant can write.

  Only bites when `EMBED_ORIGINS_LOCKED` is on; with the cap off this is a
  no-op and #1130/#1131 behaviour is unchanged. Only looks at the attribute
  when the changeset is *changing* it: a row written before the cap was turned
  on can still be renamed or deactivated without first being brought under the
  ceiling — the served header is clamped by `KilnCMS.Forms.EmbedPolicy` either
  way, so the stale list is not a live widening in the meantime.

  The message names the refused entries and never the ceiling — see
  `KilnCMS.Forms.EmbedCeiling` for why (it would enumerate other orgs'
  partners on a shared deployment). Runs after `CspOrigins` in each resource's
  `validations` block, so a malformed entry gets the shape error, not this one.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Forms.EmbedCeiling

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :field) do
      {:ok, field} when is_atom(field) -> {:ok, opts}
      _ -> {:error, ":field is required"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    field = Keyword.fetch!(opts, :field)

    if Ash.Changeset.changing_attribute?(changeset, field) do
      case Ash.Changeset.get_attribute(changeset, field) do
        origins when is_list(origins) -> check(field, origins)
        # `nil` is "inherit"; not-loaded is a write that does not touch it.
        _nil_or_not_loaded -> :ok
      end
    else
      :ok
    end
  end

  @impl true
  def describe(_opts),
    do: [message: "must stay within the framing allowed for this deployment", vars: []]

  defp check(field, origins) do
    case EmbedCeiling.outside(origins) do
      [] ->
        :ok

      refused ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: field,
           message:
             "may not open framing to %{origins}: the operator has capped which sites may " <>
               "embed forms on this deployment. Ask them to allow it, or remove it here.",
           vars: [origins: Enum.join(refused, ", ")]
         )}
    end
  end
end
