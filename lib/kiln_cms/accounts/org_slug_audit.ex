defmodule KilnCMS.Accounts.OrgSlugAudit do
  @moduledoc """
  Find the organizations whose stored slug can't be a hostname (#1710), and
  downcase the ones where that is all it takes.

  Before 1.0 an `Organization.slug` had no format rule, but tenant resolution
  downcases the request host and then matches the slug exactly — so an org
  stored as `Acme`, `my_site` or `a.b` is unreachable at `<slug>.<base host>`
  (and at `<slug>.<console host>`). New writes are normalized and checked
  (`KilnCMS.Accounts.OrgSlug`); rows written before that are left as they are,
  because renaming a live tenant's host is the operator's decision.

  `report/0` sorts each such org into one of two lists:

    * **fixable** — downcasing alone makes it a valid, unreserved label, and no
      other org's slug downcases to the same thing. Its subdomain was never
      reachable (the lookup is downcased), so downcasing it breaks nothing
      that worked — it makes the subdomain start working. `fix/0` does this.
    * **manual** — anything else: not a label even downcased (`my_site`),
      reserved (`www`), or colliding with another org (`Acme` when `acme`
      exists, or `Acme` beside `ACME`). The operator picks a new slug.

  `mix kiln.org_slugs [--fix]` prints it; in a release,
  `bin/kiln_cms eval 'KilnCMS.Release.org_slugs()'`. The application warns at
  boot while the report is not empty.
  """

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Organization
  alias KilnCMS.Accounts.OrgSlug

  @typedoc """
  One org whose slug can't be a hostname: `problem` is what is wrong with the
  stored slug, `fix` the downcased slug `fix/0` would store (`nil` when there
  is none), and `blocked` why there is none.
  """
  @type finding :: %{
          org: %Organization{},
          problem: :format | :reserved,
          fix: String.t() | nil,
          blocked: nil | :format | :reserved | {:collision, [String.t()]}
        }

  @doc """
  Every org whose slug fails `KilnCMS.Accounts.OrgSlug.check/1`, split into
  `:fixable` and `:manual` findings (see the module doc).
  """
  @spec report() :: %{fixable: [finding()], manual: [finding()]}
  def report do
    # `authorize?: false`: operator tooling and a boot advisory, with no actor.
    # Nothing here is reachable from a web surface.
    orgs = Accounts.list_organizations!(authorize?: false, query: [sort: [slug: :asc]])
    by_normalized = Enum.group_by(orgs, &OrgSlug.normalize(&1.slug), & &1.slug)

    orgs
    |> Enum.flat_map(fn org ->
      case OrgSlug.check(org.slug) do
        :ok -> []
        {:error, problem} -> [finding(org, problem, by_normalized)]
      end
    end)
    |> Enum.split_with(&is_binary(&1.fix))
    |> then(fn {fixable, manual} -> %{fixable: fixable, manual: manual} end)
  end

  defp finding(org, problem, by_normalized) do
    candidate = OrgSlug.normalize(org.slug)
    others = List.delete(Map.get(by_normalized, candidate, []), org.slug)

    blocked =
      case {OrgSlug.check(candidate), others} do
        {{:error, still}, _others} -> still
        {:ok, []} -> nil
        {:ok, others} -> {:collision, others}
      end

    %{org: org, problem: problem, fix: if(blocked, do: nil, else: candidate), blocked: blocked}
  end

  @doc """
  Downcase the slug of every `:fixable` org in `report/0`, logging each one.
  Returns the renamed orgs, or the first org that could not be written.
  """
  @spec fix() :: {:ok, [Organization.t()]} | {:error, {Organization.t(), term()}}
  def fix do
    report().fixable
    |> Enum.reduce_while({:ok, []}, fn %{org: org, fix: slug}, {:ok, done} ->
      # `authorize?: false`: see `report/0`.
      case Accounts.update_organization(org, %{slug: slug}, authorize?: false) do
        {:ok, updated} ->
          # A warning, not info: a tenant's host just changed, and that belongs
          # in the log a production deployment actually keeps.
          Logger.warning(
            "Organization #{org.id} slug downcased from #{inspect(org.slug)} to #{inspect(slug)} (#1710)"
          )

          {:cont, {:ok, [updated | done]}}

        {:error, error} ->
          {:halt, {:error, {org, error}}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  @doc """
  The boot warning's text, or `nil` when every slug is a valid host label.
  """
  @spec warning(%{fixable: [finding()], manual: [finding()]}) :: String.t() | nil
  def warning(%{fixable: [], manual: []}), do: nil

  def warning(%{fixable: fixable, manual: manual}) do
    slugs = Enum.map_join(fixable ++ manual, ", ", &inspect(&1.org.slug))

    "#{length(fixable) + length(manual)} organization slug(s) can't be a hostname, so " <>
      "those sites are unreachable at their subdomain: #{slugs}. Run `mix kiln.org_slugs` " <>
      "(in a release: bin/kiln_cms eval 'KilnCMS.Release.org_slugs()') to see which can " <>
      "simply be downcased (`--fix`) and which need a new slug."
  end

  @doc """
  What `mix kiln.org_slugs` and `KilnCMS.Release.org_slugs/1` run: `fix/0`
  first when `fix: true`, then `report/0`, printed through `shell`. `:ok` when
  every slug is a valid host label, `{:error, message}` otherwise.
  """
  @spec run_and_report(keyword(), (String.t() -> any())) :: :ok | {:error, String.t()}
  def run_and_report(opts, shell) do
    with :ok <- maybe_fix(opts[:fix], shell) do
      case print_report(shell) do
        :ok ->
          shell.("Every organization's slug is a valid host label.")
          :ok

        {:pending, count} ->
          {:error, "#{count} organization slug(s) can't be a hostname; see above."}
      end
    end
  end

  defp maybe_fix(true, shell) do
    case fix() do
      {:ok, orgs} ->
        shell.("Downcased #{length(orgs)} organization slug(s).")
        :ok

      {:error, {org, error}} ->
        message = if is_exception(error), do: Exception.message(error), else: inspect(error)
        {:error, "Could not downcase the slug #{inspect(org.slug)}: #{message}"}
    end
  end

  defp maybe_fix(_flag, _shell), do: :ok

  defp print_report(shell) do
    %{fixable: fixable, manual: manual} = report()

    shell.("Organizations whose slug can't be a hostname: #{length(fixable) + length(manual)}")

    Enum.each(fixable, fn %{org: org, fix: slug} ->
      shell.("  #{inspect(org.slug)} (#{org.name}, #{org.id}) -> #{inspect(slug)} with --fix")
    end)

    Enum.each(manual, fn %{org: org, blocked: blocked} ->
      shell.("  #{inspect(org.slug)} (#{org.name}, #{org.id}): #{why(blocked)}")
    end)

    if fixable != [] do
      shell.("  Downcase the ones marked --fix: mix kiln.org_slugs --fix")
    end

    if manual != [] do
      shell.(
        "  Give the others a new slug yourself (lowercase a-z, 0-9 and '-'), and move " <>
          "their DNS with it."
      )
    end

    case length(fixable) + length(manual) do
      0 -> :ok
      count -> {:pending, count}
    end
  end

  defp why(:format), do: "not a hostname label even downcased; needs a new slug"
  defp why(:reserved), do: "reserved for the system's own hosts; needs a new slug"

  defp why({:collision, others}),
    do:
      "downcased it would clash with #{Enum.map_join(others, ", ", &inspect/1)}; needs a new slug"
end
