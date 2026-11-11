defmodule KilnCMS.Security.Posture.Checks.Release do
  @moduledoc """
  `core.release` (#2252): whether a newer Kiln release exists, read from
  `Kiln.Updates`' cache only (`Kiln.Updates.cached/0`), so the check never
  waits on the network. On a cold cache it asks `Kiln.Updates.warm/0` to run
  the non-forced check in the background, outside this check's deadline, and
  answers `:unknown` until the answer is cached.

  Behind any release warns; current passes; checks turned off
  (`KILN_UPDATE_CHECK=false`) is `:n_a`; a failed or pending check is
  `:unknown`, never a pass.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Security.Posture

  @impl Kiln.Security.Check
  def id, do: "core.release"

  @impl Kiln.Security.Check
  def title, do: gettext("Kiln version")

  @impl Kiln.Security.Check
  def description,
    do: gettext("Security fixes reach an installation only when it is updated.")

  @impl Kiln.Security.Check
  def scope, do: :deployment

  @impl Kiln.Security.Check
  def run(_context) do
    opts = [fix_path: "/editor/system", docs_url: Posture.docs_url("kiln-version")]

    case Kiln.Updates.cached() do
      nil ->
        Kiln.Updates.warm()

        unknown(
          gettext("Checking for updates; reopen this page in a minute."),
          Keyword.put(opts, :facts, %{pending: true})
        )

      {:ok, :current} ->
        pass(
          gettext("This is the newest Kiln release."),
          Keyword.put(opts, :facts, %{behind: false})
        )

      {:ok, {:behind, release}} ->
        warn(
          gettext("Kiln %{version} is available; this is %{current}.",
            version: to_string(release.version),
            current: Kiln.Version.version()
          ),
          Keyword.put(opts, :facts, %{behind: true, latest: to_string(release.version)})
        )

      {:error, :disabled} ->
        n_a(gettext("Update checks are turned off (KILN_UPDATE_CHECK=false)."), opts)

      {:error, _reason} ->
        unknown(
          gettext("Could not tell whether a newer release exists. Open System to check."),
          opts
        )
    end
  end
end
