defmodule KilnCMS.Security.Posture.Checks.CoreSecurityNotices do
  @moduledoc """
  `core.security_notices` (#2522): whether a security notice kilncms.dev
  publishes covers the running Kiln (`Kiln.SecurityNotices.Core`), read from
  `Kiln.SecurityNotices`' cache only, so the check never waits on the network.
  On a cold cache it asks `Kiln.SecurityNotices.warm/0` to fetch in the
  background and answers `:unknown` until the answer is cached. The fetch is
  the one the plugin health check shares, so both checks on one page make at
  most one request.

    * a notice whose affected range covers this version — `:fail`, at any
      severity: the issue's rule, and a known hole in the running core is a
      way into the whole installation (plugins keep low and medium as warn);
    * a notice naming the core that can't be placed against this version (its
      range is unreadable, it names several packages, or this build reports
      no usable version) — `:unknown`;
    * otherwise `:pass`.

  The update check turned off (`KILN_UPDATE_CHECK=false`) is `:n_a` with no
  request, even if the plugin health check filled the cache; so is a notices
  feed that is turned off or that a fork or mirror does not name.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Kiln.Plugins.Health.Notice
  alias Kiln.SecurityNotices
  alias Kiln.SecurityNotices.Core
  alias KilnCMS.Security.Posture

  @max_details 10

  @impl Kiln.Security.Check
  def id, do: "core.security_notices"

  @impl Kiln.Security.Check
  def title, do: gettext("Security notices for Kiln")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "A published security notice for the running Kiln is a known way into the whole installation until it is updated."
      )

  @impl Kiln.Security.Check
  def scope, do: :deployment

  @impl Kiln.Security.Check
  def run(_context) do
    if Kiln.Updates.enabled?(), do: run_enabled(), else: off()
  end

  defp run_enabled do
    case SecurityNotices.cached() do
      nil ->
        SecurityNotices.warm()

        unknown(
          gettext("Checking security notices; reopen this page in a minute."),
          opts(facts: %{pending: true})
        )

      :disabled ->
        n_a(
          gettext(
            "The security notices feed is turned off (KILN_SECURITY_NOTICES_URL=false, or a fork or mirror of the update feed)."
          ),
          opts()
        )

      {:error, :invalid_notices_url} ->
        unknown(
          gettext(
            "KILN_SECURITY_NOTICES_URL is not an absolute http(s) URL, so no notice was checked."
          ),
          opts()
        )

      {:error, _reason} ->
        unknown(
          gettext("Could not reach the security notices feed. Open System to check."),
          opts()
        )

      {:ok, notices} ->
        result(Core.status(notices, Kiln.Version.version()))
    end
  end

  defp off do
    n_a(
      gettext("Security notice checks are turned off (KILN_UPDATE_CHECK=false)."),
      opts()
    )
  end

  @doc """
  The posture answer for `Kiln.SecurityNotices.Core.status/2`. Pure; `run/1`
  calls it with the cached notices, and tests with literal ones.
  """
  @spec result({:ok, Core.status()} | {:error, :unknown_version}) ::
          Kiln.Security.Check.Result.t()
  def result({:error, :unknown_version}) do
    unknown(gettext("Could not read this Kiln's version."), opts())
  end

  def result({:ok, %{version: version, affected: affected, unplaceable: unplaceable}}) do
    facts = %{
      version: version,
      affected: length(affected),
      unplaceable: length(unplaceable),
      notices: Enum.map_join(affected, ", ", & &1.id)
    }

    details =
      (Enum.map(affected, &affected_detail/1) ++ Enum.map(unplaceable, &unplaceable_detail/1))
      |> Enum.take(@max_details)

    cond do
      affected != [] ->
        fail(
          ngettext(
            "A security notice covers Kiln %{version}.",
            "%{count} security notices cover Kiln %{version}.",
            length(affected),
            version: version
          ),
          opts(details: details, facts: facts)
        )

      unplaceable != [] ->
        unknown(
          gettext("A security notice names Kiln but can't be matched to this version."),
          opts(details: details, facts: facts)
        )

      true ->
        pass(
          gettext("No published security notice covers Kiln %{version}.", version: version),
          opts(facts: facts)
        )
    end
  end

  @doc """
  One translated line for a notice that covers the running version: its id,
  severity and the release that fixes it, if one is listed. System's Updates
  card shows the same words.
  """
  @spec affected_detail(Notice.t()) :: String.t()
  def affected_detail(%Notice{} = notice) do
    case fixed_in(notice.patched) do
      nil ->
        gettext("%{id} (%{severity}): no fixed release is listed yet.",
          id: notice.id,
          severity: severity(notice.severity)
        )

      patched ->
        gettext("%{id} (%{severity}): fixed in %{patched}.",
          id: notice.id,
          severity: severity(notice.severity),
          patched: patched
        )
    end
  end

  defp unplaceable_detail(%Notice{} = notice) do
    case Kiln.Plugins.Health.Evaluate.parse_affected(notice.affected) do
      :error ->
        gettext("%{id}: its affected versions can't be read.", id: notice.id)

      {:ok, _requirements} ->
        gettext("%{id} names several packages; whether it covers Kiln can't be told.",
          id: notice.id
        )
    end
  end

  # The published text as is, for the reader only: it never decides the
  # verdict (`Kiln.SecurityNotices.Core`). Blank and `unknown` say nothing.
  defp fixed_in(patched) when is_binary(patched) do
    trimmed = String.trim(patched)
    if trimmed == "" or String.downcase(trimmed) == "unknown", do: nil, else: trimmed
  end

  defp fixed_in(_patched), do: nil

  defp severity(:low), do: gettext("low")
  defp severity(:medium), do: gettext("medium")
  defp severity(:high), do: gettext("high")
  defp severity(:critical), do: gettext("critical")
  defp severity(_unknown), do: gettext("severity unknown")

  defp opts(extra \\ []) do
    Keyword.merge(
      [fix_path: "/editor/system", docs_url: Posture.docs_url("security-notices-for-kiln")],
      extra
    )
  end
end
