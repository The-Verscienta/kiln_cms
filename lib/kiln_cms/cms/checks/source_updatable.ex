defmodule KilnCMS.CMS.Checks.SourceUpdatable do
  @moduledoc """
  Authorizes a payload-link write (`ContentLink`'s `:create_link`,
  `:update_link`, `:destroy_link`) only when the actor may **update the
  link's source record** (relationships plan, R8; `KilnCMS.CMS.PayloadLinks`).

  Delegation, as `Checks.LinkEndsReadable` delegates reads: the source's own
  update policy is asked (`Ash.can?/3`), not restated here, so a scoped
  editor's `editable_types`, a read-only API key and whatever the content
  policies gain later all apply to links exactly as to the record. A source
  that cannot be found denies.
  """
  use Ash.Policy.SimpleCheck

  alias KilnCMS.CMS.PayloadLinks

  @impl Ash.Policy.Check
  def describe(_opts), do: "the actor may update the link's source record"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    tenant = changeset.to_tenant || changeset.tenant

    case PayloadLinks.locate(Ash.Changeset.get_attribute(changeset, :source_id), tenant) do
      {:ok, source} -> Ash.can?({source, :update}, actor, tenant: tenant)
      :error -> false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
