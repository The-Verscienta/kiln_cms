defmodule KilnCMS.Accounts.User.Senders.SendRegistrationDecision do
  @moduledoc """
  Tells an applicant what a site's admin decided about their registration
  (#2251).

  Sent by `KilnCMS.Accounts.Changes.MailRegistrationDecision` after the
  decision committed:

    * **approved** — "Your registration on (site) was approved", with a sign-in
      link on the site's host for a viewer (`ConsoleHost.tier_url/3`). Also
      when a rejection is reversed;
    * **rejected** — "Your registration on (site) wasn't approved." and
      nothing else: no reason, no name of who decided, no link.

  Best effort: a mail that cannot be queued is logged and the decision stands.
  """
  require Logger

  import Swoosh.Email

  alias KilnCMS.Mail
  alias KilnCMSWeb.Plugs.ConsoleHost

  @spec deliver(
          :approve | :reject,
          KilnCMS.Accounts.User.t(),
          KilnCMS.Accounts.Organization.t(),
          atom()
        ) :: :ok
  def deliver(outcome, applicant, org, role) do
    site = escape(KilnCMS.Branding.for_org(org).site_name)

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(applicant.email))
    |> subject(subject_line(outcome, KilnCMS.Branding.for_org(org).site_name))
    |> html_body(body(outcome, site, org, role))
    |> Mail.enqueue!(org_id: org.id)
  rescue
    # Boundary: the decision has committed; a mail fault must not turn the
    # admin's successful decision into a crash. The module only: the message
    # can carry the recipient's address.
    error ->
      Logger.warning("Could not queue a registration decision: #{inspect(error.__struct__)}")
      :ok
  end

  defp subject_line(:approve, site), do: "Your registration on #{site} was approved"
  defp subject_line(:reject, site), do: "About your registration on #{site}"

  defp body(:approve, site, org, role) do
    """
    <p>Your registration on #{site} was approved.</p>
    <p><a href="#{ConsoleHost.tier_url("/sign-in", org, role)}">Sign in</a> to get started.</p>
    """
  end

  defp body(:reject, site, _org, _role) do
    """
    <p>Your registration on #{site} wasn't approved.</p>
    """
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
