defmodule KilnCMSWeb.SignInUnlockController do
  @moduledoc """
  The sign-in unlock pages (#2250): `/sign-in/unlock` asks for a link, and
  `/auth/unlock/:unlock_token` is the page the emailed link opens.

  Plain controller pages on `:browser_auth`, behind the admin allowlist, like
  `/sign-in/verify`: every request pays the `:auth` per-IP bucket, the forms
  carry a CSRF token, and nothing on either page needs JavaScript.

  ## Asking for a link says nothing about the address

  The request form answers one fixed sentence for every address — unknown,
  known, paused, out of mail budget — because the work behind it
  (`KilnCMS.Accounts.SignInUnlock.request/2`) is handed off before anything is
  looked up. The page never says an account is paused; the sign-in page links
  here with the same words whether or not it is. The form is never prefilled
  from the URL, so a crafted link cannot fill in someone else's address.

  ## Opening the link spends nothing

  A `GET` of the link renders the same page for any token, real or not, and
  spends nothing: mail scanners follow links. The button posts back to the same
  path, and only that redeems. Every refusal renders one page, which allows for
  a scanner that clicked through as well. A redeemed link signs nobody in: it
  redirects to `/sign-in` with a flash that promises nothing, because a
  challenge, the per-IP limit or a second factor may still stand in the way.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SignInUnlock
  alias KilnCMS.Security.AuthEvents

  def new(conn, _params), do: render_request(conn, 200, sent?: false)

  def create(conn, %{"email" => email}) when is_binary(email) do
    case String.trim(email) do
      "" -> ask_again(conn)
      address -> request(conn, address)
    end
  end

  def create(conn, _params), do: ask_again(conn)

  defp request(conn, address) do
    # authorize?: false — a system-only action with no actor: anyone may ask,
    # the answer is one fixed sentence, and the org is the request host's.
    case Accounts.request_sign_in_unlock(address,
           authorize?: false,
           context: AuthEvents.context(conn)
         ) do
      :ok -> render_request(conn, 200, sent?: true)
      # Only input the action itself refuses reaches here, never anything
      # about the address's account: that is decided after the hand-off.
      {:error, _invalid} -> ask_again(conn)
    end
  end

  defp ask_again(conn) do
    render_request(conn, 422,
      sent?: false,
      error: gettext("Enter the email address you sign in with.")
    )
  end

  def show(conn, %{"unlock_token" => token}) do
    conn
    |> put_status(200)
    |> render_page(:show,
      page_title: gettext("Lift the sign-in pause"),
      action: ~p"/auth/unlock/#{token}"
    )
  end

  def redeem(conn, %{"unlock_token" => token}) do
    # authorize?: false — a system-only action with no actor: the emailed link
    # is the credential, and the action binds it to this request's site.
    case Accounts.redeem_sign_in_unlock(token,
           authorize?: false,
           context: AuthEvents.context(conn)
         ) do
      :ok ->
        conn
        |> put_flash(
          :info,
          gettext(
            "The sign-in pause on your account is lifted. You may be asked to complete a check, or to wait a minute if your network is busy."
          )
        )
        |> redirect(to: ~p"/sign-in")

      {:error, _refused} ->
        conn
        |> put_status(422)
        |> render_page(:invalid, page_title: gettext("Lift the sign-in pause"))
    end
  end

  defp render_request(conn, status, opts) do
    conn
    |> put_status(status)
    |> render_page(:new,
      page_title: gettext("Lift a sign-in pause"),
      sent?: Keyword.fetch!(opts, :sent?),
      error: Keyword.get(opts, :error),
      minutes: div(SignInUnlock.ttl_seconds(), 60)
    )
  end

  # `Layouts.auth/1`, as `/sign-in/verify` draws it (#1676): the site's brand
  # row, both themes and the request's locale from the root layout.
  defp render_page(conn, template, assigns) do
    conn
    |> put_layout(html: {KilnCMSWeb.Layouts, :auth})
    |> put_view(html: KilnCMSWeb.SignInUnlockHTML)
    |> render(template, assigns)
  end
end
