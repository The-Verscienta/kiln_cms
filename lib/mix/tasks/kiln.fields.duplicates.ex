defmodule Mix.Tasks.Kiln.Fields.Duplicates do
  @shortdoc "Report values that repeat in custom fields marked unique (read-only)"

  @moduledoc """
  Audits the `unique` field constraint (#2276): lists, per content type and
  field, the values more than one live record holds.

      mix kiln.fields.duplicates                  # every type of the default org
      mix kiln.fields.duplicates --org acme
      mix kiln.fields.duplicates --type herb --samples 20

  Uniqueness is enforced by the write path (`KilnCMS.CMS.UniqueValues`), which
  raw SQL, `update_all` and a database restore bypass, and which can lag a
  rollout (a field made unique while writes were in flight on an older node).
  This task finds what slipped through. It scopes exactly like the runtime
  check — organization, table or dynamic type, locale; trashed records
  ignored — and **writes nothing**.

  Options:

      --org SLUG      the organization (default: the default org)
      --type NAME     only this content type
      --samples N     values shown per field (default 5)

  Exits non-zero when it finds repeated values, so it can gate a deploy.
  """

  use Mix.Task

  alias KilnCMS.CMS.FieldConversion
  alias KilnCMS.CMS.UniqueValues

  @switches [org: :string, type: :string, samples: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    org_id =
      case FieldConversion.org_id(opts[:org]) do
        {:ok, org_id} -> org_id
        {:error, message} -> Mix.raise(message)
      end

    case UniqueValues.audit(org_id, opts[:type], opts[:samples] || 5) do
      [] ->
        Mix.shell().info("No repeated values in unique fields.")

      found ->
        Enum.each(found, &print/1)
        Mix.raise("#{length(found)} unique field(s) hold repeated values")
    end
  end

  defp print(%{type: type, field: field, label: label, groups: groups, samples: samples}) do
    Mix.shell().info("#{type}.#{field} (#{label}): #{groups} repeated value(s)")

    for %{value: value, count: count, locale: locale} <- samples do
      Mix.shell().info("  #{Jason.encode!(value)} x#{count}#{if locale, do: " [#{locale}]"}")
    end
  end
end
