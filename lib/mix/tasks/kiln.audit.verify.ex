defmodule Mix.Tasks.Kiln.Audit.Verify do
  @shortdoc "Verify tamper-evident history anchors (#356)"

  @moduledoc """
  Recompute every anchored document's version chain and compare it against the
  latest recorded (signed) anchor:

      mix kiln.audit.verify

  Prints one line per anchored document and exits non-zero if any chain fails
  to reproduce its anchor — i.e. anchored history was altered, deleted, or
  reordered, or an anchor signature no longer verifies. `unsigned` (intact but
  minted without a signing key) and `unanchored tail` states are informational.
  """
  use Mix.Task

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Governance.Chain

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    results =
      for ct <- ContentTypes.all(),
          record <- Ash.read!(ct.resource, authorize?: false),
          verdict = Chain.verify(ct.resource, to_string(ct.type), record.id, record.org_id),
          verdict != :unanchored do
        line(ct.type, record, verdict)
        verdict
      end

    tampered = Enum.count(results, &match?({:tampered, _}, &1))

    Mix.shell().info("#{length(results)} anchored document(s) checked, #{tampered} failure(s).")

    if tampered > 0, do: exit({:shutdown, 1})
  end

  defp line(type, record, verdict) do
    status =
      case verdict do
        :verified -> "VERIFIED"
        :unsigned -> "intact (unsigned)"
        {:tampered, reason} -> "TAMPERED — #{reason}"
      end

    Mix.shell().info("#{type}/#{record.slug} (#{record.id}): #{status}")
  end
end
