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

  The one exception is AshAi's tool-listing probe (the `/mcp` link tools):
  it asks about a blank changeset with no source, which this check could
  never pass, so the tools would never be offered. A probe without a source
  passes here; the other policies on the action (write key, editor role)
  still decide whether the tool is listed, and the real call names a source
  and is judged on it. Only AshAi sets that private context key, and a
  client cannot write `private`.
  """
  use Ash.Policy.SimpleCheck

  alias KilnCMS.CMS.PayloadLinks

  @impl Ash.Policy.Check
  def describe(_opts), do: "the actor may update the link's source record"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    tenant = changeset.to_tenant || changeset.tenant
    source_id = Ash.Changeset.get_attribute(changeset, :source_id)

    if is_nil(source_id) and tool_probe?(changeset) do
      true
    else
      case PayloadLinks.locate(source_id, tenant) do
        {:ok, source} -> Ash.can?({source, :update}, actor, tenant: tenant)
        :error -> false
      end
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp tool_probe?(%Ash.Changeset{context: %{private: %{ash_ai_pre_check?: true}}}), do: true
  defp tool_probe?(_changeset), do: false
end
