defmodule KilnCMS.Accounts.User.Senders.SendMembershipNotice do
  @moduledoc """
  Tells an existing account it was added to a site (#2135), when an admin
  enters its address on the Team page.

  Sent by `KilnCMS.Accounts.Invitations.AddOrInvite` after the membership
  committed, and only there — not from `OrgMembership.:create`, which billing,
  site sign-on, the audience checkboxes and the legacy carry also call, and
  none of those is a person being added by someone.

  Best effort: a mail that cannot be queued is logged and the membership
  stands. Budgeted per address (`:membership_notice`) like the other mail an
  admin can aim at anyone, and dropped silently once the budget is spent; the
  admin is told "Member added." either way, because the membership is what
  they asked for.
  """
  use KilnCMSWeb, :verified_routes

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Mail
  alias KilnCMSWeb.Plugs.ConsoleHost

  import Swoosh.Email

  @spec deliver(Accounts.User.t(), Accounts.Organization.t(), term()) :: :ok
  def deliver(user, org, role) do
    address = to_string(user.email)

    if AccountThrottle.allow_mail?(:membership_notice, address) do
      site = KilnCMS.Branding.for_org(org).site_name

      new()
      |> from(Application.fetch_env!(:kiln_cms, :email_from))
      |> to(address)
      |> subject("You were added to #{site}")
      |> html_body(body(escape(site), ConsoleHost.tier_url("/sign-in", org, role), role))
      |> Mail.enqueue!(org_id: org.id)
    else
      :ok
    end
  rescue
    # Boundary: the membership has committed; a mail fault must not turn the
    # admin's successful add into a crash.
    # The module only: the message can carry the recipient's address.
    error ->
      Logger.warning("Could not queue a membership notice: #{inspect(error.__struct__)}")
      :ok
  end

  defp body(site, link, role) do
    """
    <p>You now have access to #{site} as #{tier(role)}.</p>
    <p><a href="#{link}">Sign in</a> with your existing account to get started.</p>
    """
  end

  defp tier(:admin), do: "an admin"
  defp tier(:editor), do: "an editor"
  defp tier(_viewer), do: "a viewer"

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
