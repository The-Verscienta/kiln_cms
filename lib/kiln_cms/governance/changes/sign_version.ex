defmodule KilnCMS.Governance.Changes.SignVersion do
  @moduledoc """
  Signs a version row as it is created (#598 / #670).

  Mixed into every PaperTrail version resource through the shared `paper_trail`
  `mixin`, so it applies to `Page.Version`, `Post.Version`, `Entry.Version` and
  every overlay tier without a per-resource edit.

  ## In `before_action`, and reading the changeset rather than the record

  The signature covers the row's own identity — its id, its source, its org and
  its insert timestamp — and all four are settled by the time `before_action`
  runs: `id` and `version_inserted_at` come from attribute defaults, which Ash
  applies while building the changeset.

  It has to be `before_action` and not `after_action`: the signature is a column
  on this row, so it must be part of the same INSERT. Signing afterwards would
  mean a second write, outside the source's transaction, that could fail and
  leave a permanently unsigned row behind — indistinguishable from a splice.

  ## A signing failure never fails the write

  `VersionSignature.sign/1` answers `{nil, nil}` when no key is configured, which
  is the normal state of a default install. An editorial save must not fail
  because the governance chain cannot sign — the chain's own anchor path makes
  the same choice, and `verify/4` reports an unsigned row honestly rather than
  pretending.
  """
  use Ash.Resource.Change

  alias KilnCMS.Governance.VersionSignature

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &sign/1)
  end

  defp sign(changeset) do
    identity = %{
      org_id: Ash.Changeset.get_attribute(changeset, :org_id),
      resource_type: resource_type(changeset.resource),
      source_id: Ash.Changeset.get_attribute(changeset, :version_source_id),
      version_id: Ash.Changeset.get_attribute(changeset, :id),
      version_inserted_at: Ash.Changeset.get_attribute(changeset, :version_inserted_at)
    }

    {signature, key_id} = VersionSignature.sign(identity)

    changeset
    |> Ash.Changeset.force_change_attribute(:chain_signature, signature)
    |> Ash.Changeset.force_change_attribute(:chain_key_id, key_id)
  end

  @doc """
  The storage type name a version resource belongs to — `KilnCMS.CMS.Page.Version`
  → `"page"`.

  Public because `KilnCMS.Governance.Chain` has to derive the identical string
  when it verifies: the type is inside the signed payload, so the two sides
  disagreeing means every signature fails for no reason a reader could find.
  """
  @spec resource_type(module()) :: String.t()
  def resource_type(version_resource) do
    version_resource
    |> Module.split()
    |> Enum.drop(-1)
    |> Module.concat()
    |> then(&KilnCMS.Firing.Engine.document_type(struct(&1)))
    |> to_string()
  end
end
