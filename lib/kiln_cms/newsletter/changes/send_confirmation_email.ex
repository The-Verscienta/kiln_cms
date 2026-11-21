defmodule KilnCMS.Newsletter.Changes.SendConfirmationEmail do
  @moduledoc """
  Mails the double-opt-in confirmation link after a `:subscribe` (issue #586).

  Without this the whole opt-in flow was inert: `:subscribe` minted a
  `confirm_token` and `/newsletter/confirm/:token` consumed one, but nothing
  ever put a token in front of a human. The mailed link is a GET that renders a
  one-button page; the button's POST is what confirms (#1664), so a link
  prefetcher following it confirms nothing.

  ## Only a `:pending` row is mailed

  `:subscribe` upserts on email with `upsert_fields [:name]`, so a repeat
  sign-up returns the *stored* row — status and tokens untouched. This hook
  reads that returned row and mails only when it is `:pending`:

    * `:confirmed` — nothing to confirm, and re-sending would turn the public
      endpoint into a way to mail an arbitrary address on demand;
    * `:unsubscribed` — the non-resurrection rule in `:subscribe` is what keeps
      an opt-out honoured indefinitely; mailing them a link that undoes it would
      hand that decision back to whoever submitted the form. A member who
      changes their mind re-opts in from `/account`, an admin from
      `/editor/newsletter`.

  Consequently the confirmation link carries the row's **persisted** token, not
  the one the changeset generated — on an upsert those differ, and only the
  persisted one resolves.

  ## Not attached to `:link_member`

  Activating a paid membership does not mail a newsletter opt-in prompt. A
  purchase is not a request for marketing email, and the person did not ask for
  the message; `/account` is where a member turns it on. See
  `KilnCMS.Newsletter.TierSync`.

  ## In the language the visitor signed up in

  The mail is written in the Gettext locale of the process running
  `:subscribe` (#2597): the sign-up's request, whose locale is the page's
  (a sign-up block posts to a path pinned to it, #2465). The message is built
  here, before it is queued, so the worker that delivers it needs no locale of
  its own and the subscriber row stores none. The link carries the same
  language prefix (`KilnCMS.I18n.pinned_path/2`), so the confirmation page it
  opens is in that language too.

  Delivery goes through `KilnCMS.Mail.enqueue!/1` (one Oban job on the `:mail`
  queue), inserted inside the action's transaction — so a subscribe that rolls
  back cannot leave a confirmation email in flight.
  """
  use Ash.Resource.Change
  use KilnCMSWeb, :verified_routes
  use Gettext, backend: KilnCMSWeb.Gettext

  import Swoosh.Email

  alias KilnCMS.I18n
  alias KilnCMS.Mail
  alias KilnCMSWeb.Tenant

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      maybe_send(record)
      {:ok, record}
    end)
  end

  # `confirm_token` is nil-guarded rather than assumed: a row predating the
  # token generator would otherwise be mailed a link that can never resolve.
  defp maybe_send(%{status: :pending, confirm_token: token} = subscriber)
       when is_binary(token) do
    brand = KilnCMS.Branding.for_org(subscriber.org_id)
    locale = KilnCMSWeb.Gettext |> Gettext.get_locale() |> I18n.normalize()
    # The org's OWN base URL (epic #336) — a tenant on a custom domain must not
    # be sent a confirmation link pointing at the deployment-global host.
    url =
      Tenant.base_url(subscriber.org_id) <>
        I18n.pinned_path(locale, ~p"/newsletter/confirm/#{token}")

    new()
    |> from(Application.fetch_env!(:kiln_cms, :email_from))
    |> to(to_string(subscriber.email))
    |> subject(gettext("Confirm your subscription to %{site}", site: brand.site_name))
    |> html_body(body(brand.site_name, url, locale))
    # Through the site's own relay when it has one (#1322).
    |> Mail.enqueue!(org_id: subscriber.org_id)
  end

  defp maybe_send(_subscriber), do: :ok

  # No scripts and no images, so the mail renders in a text-first client and
  # nothing here needs the browser CSP. The site name is HTML-escaped (it is
  # admin-controlled, not a literal); the URL is a token this module minted.
  #
  # Each paragraph is escaped whole, translation and all: a catalog is text,
  # not markup. `lang` says which language the paragraphs are in.
  defp body(site_name, url, locale) do
    intro =
      gettext("Confirm this address to start receiving the newsletter from %{site}:",
        site: site_name
      )

    ignore =
      gettext(
        "If you didn't ask for this, ignore this email. The address is not subscribed and won't receive anything unless the link above is clicked."
      )

    """
    <div lang="#{h(locale)}">
    <p>#{h(intro)}</p>
    <p><a href="#{url}">#{url}</a></p>
    <p>#{h(ignore)}</p>
    </div>
    """
  end

  defp h(value) do
    value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
