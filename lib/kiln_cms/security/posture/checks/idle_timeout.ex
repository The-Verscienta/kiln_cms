defmodule KilnCMS.Security.Posture.Checks.IdleTimeout do
  @moduledoc """
  `core.idle_timeout` (#2252): whether the site signs idle browsers out
  (`KilnCMS.Accounts.IdleTimeout`, #2246). Warns when neither the general nor
  the administrators' timeout is set.

  Reads the policy with `IdleTimeout.read_policy/1`, the same row and
  conversion enforcement uses but uncached and able to say it could not read
  it: enforcement fails open to "off" there, and this answers `:unknown`
  instead of reporting a timeout it cannot see as unset.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Accounts.IdleTimeout
  alias KilnCMS.Security.Posture

  @impl Kiln.Security.Check
  def id, do: "core.idle_timeout"

  @impl Kiln.Security.Check
  def title, do: gettext("Idle sign-out")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "A browser left signed in on a shared or lost computer stays signed in until someone signs it out."
      )

  @impl Kiln.Security.Check
  def scope, do: :site

  @impl Kiln.Security.Check
  def run(%{org_id: org_id}) do
    opts = [fix_path: "/editor/sessions", docs_url: Posture.docs_url("idle-sign-out")]

    case IdleTimeout.read_policy(org_id) do
      {:ok, %{idle_seconds: nil, admin_idle_seconds: nil}} ->
        warn(
          gettext("Idle browsers are never signed out."),
          Keyword.put(opts, :facts, %{idle_minutes: nil, admin_idle_minutes: nil})
        )

      {:ok, policy} ->
        pass(
          gettext("Idle browsers are signed out."),
          Keyword.put(opts, :facts, %{
            idle_minutes: minutes(policy.idle_seconds),
            admin_idle_minutes: minutes(policy.admin_idle_seconds)
          })
        )

      :error ->
        unknown(gettext("The site's session settings could not be read."), opts)
    end
  end

  defp minutes(nil), do: nil
  defp minutes(seconds), do: div(seconds, 60)
end
