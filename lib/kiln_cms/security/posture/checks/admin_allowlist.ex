defmodule KilnCMS.Security.Posture.Checks.AdminAllowlist do
  @moduledoc """
  `core.admin_allowlist` (#2252): the networks the site's console and sign-in
  may be reached from (`KilnCMS.Security.AdminAllowlist`, #2248).

  A list is optional, so no list is `:n_a`, not a warning. A list is a pass,
  unless the operator's switch (`KILN_ADMIN_ALLOWLIST_DISABLED`) is on on this
  node, which makes the gates ignore it: that fails, because the page would
  otherwise say the console is restricted when it is not. The stored list is
  read with `AdminAllowlist.configured/1`, the gates' own read with the switch
  left out, so the page can see a list the switch is hiding. A list that could
  not be read is `:unknown`.
  """
  use Kiln.Security.Check
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Security.AdminAllowlist
  alias KilnCMS.Security.Posture

  @impl Kiln.Security.Check
  def id, do: "core.admin_allowlist"

  @impl Kiln.Security.Check
  def title, do: gettext("Admin allowlist")

  @impl Kiln.Security.Check
  def description,
    do:
      gettext(
        "When administrators always sign in from known networks (an office, a VPN), an allowlist keeps everyone else away from the console and sign-in."
      )

  @impl Kiln.Security.Check
  def scope, do: :site

  @impl Kiln.Security.Check
  def run(%{org_id: org_id}) do
    opts = [fix_path: "/editor/admin-allowlist", docs_url: Posture.docs_url("admin-allowlist")]
    switch? = AdminAllowlist.disabled?()

    case AdminAllowlist.configured(org_id) do
      :off ->
        n_a(
          gettext(
            "No admin allowlist (optional; useful when administrators sign in from fixed networks)."
          ),
          Keyword.put(opts, :facts, %{entries: 0, operator_disabled: switch?})
        )

      {:on, cidrs} when switch? ->
        fail(
          gettext(
            "The site has an admin allowlist, but the operator's switch (KILN_ADMIN_ALLOWLIST_DISABLED) turns it off, so any network can reach the console."
          ),
          Keyword.put(opts, :facts, %{entries: length(cidrs), operator_disabled: true})
        )

      {:on, cidrs} ->
        pass(
          ngettext(
            "Only %{count} listed network can reach the console and sign-in.",
            "Only %{count} listed networks can reach the console and sign-in.",
            length(cidrs)
          ),
          Keyword.put(opts, :facts, %{entries: length(cidrs), operator_disabled: false})
        )

      :unavailable ->
        unknown(gettext("The site's admin allowlist could not be read."), opts)
    end
  end
end
