defmodule KilnCMS.Accounts.User.Senders.SendInvitation do
  @moduledoc """
  The mail an invitation (#2135) sends: who invited the recipient, to which
  site, at which tier, and the link that accepts it.

  The link opens on the invited site's own host
  (`KilnCMSWeb.Plugs.ConsoleHost.tier_url/3`) — its public site host for a
  `:viewer`, its console host (when the console gate is on) for an editor or
  admin — never on whichever host the admin happened to be on, so the account
  is set up where the invitee will use it.

  No free-text message from the inviter: a field anyone with admin rights can
  fill and have delivered from this instance's address is a phishing channel.
  The site and inviter names are HTML-escaped in the body; both are typed by
  people. The subject is plain text, so it carries the site name as it is.

  The per-address budget is charged by the caller
  (`KilnCMS.Accounts.Changes.SendInvitation`) so a refusal can be reported, so
  this does not charge it again.
  """
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Invitations
  alias KilnCMS.Mail
  alias KilnCMSWeb.Plugs.ConsoleHost

  import Swoosh.Email

  @doc """
  Queue the mail. `site` is the invited site's name, resolved by the caller
  before its transaction (`KilnCMS.Accounts.Changes.SendInvitation`).
  """
  @spec deliver(Accounts.Invitation.t(), String.t(), term(), String.t()) :: :ok
  def deliver(invitation, token, inviter, site) do
    org = organization(invitation.organization_id)
    link = ConsoleHost.tier_url("/auth/invite/#{token}", org, invitation.role)

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(invitation.email))
    |> subject("You've been invited to #{site}")
    |> html_body(body(escape(site), link, inviter_name(inviter), invitation.role))
    |> Mail.enqueue!(org_id: invitation.organization_id)
  end

  defp body(site, link, inviter, role) do
    """
    <p>#{invited_by(inviter)} invited you to #{site} as #{tier(role)}.</p>
    <p><a href="#{link}">Accept the invitation</a></p>
    <p>Or open this link: #{link}</p>
    <p>The link works once and expires in #{Invitations.ttl_days()} days. If you weren't
    expecting this, you can ignore this email — nothing is set up until the link is used.</p>
    """
  end

  defp invited_by(nil), do: "An administrator"
  defp invited_by(name), do: name

  defp inviter_name(%Accounts.User{name: name}) when is_binary(name) and name != "",
    do: escape(name)

  # No display name: say "An administrator" rather than show the inviter's
  # address — mail never puts an email where a name goes (#214, data-flows.md).
  defp inviter_name(_no_name), do: nil

  defp tier(:admin), do: "an admin"
  defp tier(:editor), do: "an editor"
  defp tier(_viewer), do: "a viewer"

  defp organization(org_id) do
    # The plain org read the accounts system actor is admitted to.
    case Accounts.get_organization(org_id, actor: Accounts.system(), not_found_error?: false) do
      {:ok, %Accounts.Organization{} = org} -> org
      _missing -> nil
    end
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
