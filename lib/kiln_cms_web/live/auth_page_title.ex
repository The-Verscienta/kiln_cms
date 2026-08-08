defmodule KilnCMSWeb.AuthPageTitle do
  @moduledoc """
  Gives each AshAuthentication page a `page_title` (#559).

  ## Why these pages needed one

  `root.html.heex` passes `live_title/1` both a `default` and a `suffix`:

      <.live_title default={brand_name} suffix={" · " <> brand_name}>

  Phoenix renders `{@prefix}{render_present(render_slot(@inner_block), @default)}{@suffix}`
  — the suffix is appended **unconditionally**, including when the slot is empty
  and `default` stands in. So a page that sets no `page_title` gets the brand
  name twice: on a white-labelled site, `/sign-in` read `Acme Docs · Acme Docs`.

  The auth pages were the only ones that hit it, because every other route sets
  a title.

  ## Why here rather than in `live_title/1`

  Making the suffix conditional is the tempting fix and it is the wrong one.
  LiveView carries `suffix` to the client as `data-suffix` and reuses it for
  client-side title updates on live navigation. A first render with no title
  would emit no suffix, and every later patch within that live session would
  then be missing it — trading a doubled brand name on one page for a dropped
  one on every page after it.

  Titling the pages leaves shared layout behaviour alone, and
  `auth_titles_test.exs` holds the line: every live route in the auth session
  must resolve to a title here, so a page added without one fails rather than
  quietly reintroducing the doubling.

  ## Why an `on_mount` hook rather than `mount/3`

  These views delegate `mount/3` wholesale to the library's
  (`KilnCMSWeb.AuthLive`), deliberately passing the return value straight
  through so an upstream release that starts answering
  `{:ok, socket, temporary_assigns: …}` keeps working. Destructuring it to add
  an assign would give that up. A hook runs before `mount/3` and needs none of
  it.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  @doc """
  Assigns `page_title` from the route's `live_action`, on mount and on each
  `handle_params`.

  Both, because `/sign-in`, `/register` and `/reset` are one LiveView in one
  live session and the links between them are `live_patch` — a mount-only hook
  titles the page you arrived on and then leaves that title in place while you
  patch to the others, so the registration form would sit under a tab reading
  "Sign in". That is worse than the doubling it replaced: naming a different
  page is a wrong answer where `Acme Docs · Acme Docs` was merely a redundant
  one.

  An action with no title is left alone rather than assigned `nil` —
  `assign(:page_title, nil)` renders exactly the doubling this exists to
  prevent, so an unmapped page should look untouched to anything inspecting it,
  and fail the test that enumerates them.
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> put_title()
      |> Phoenix.LiveView.attach_hook(:auth_page_title, :handle_params, fn _params,
                                                                           _uri,
                                                                           socket ->
        {:cont, put_title(socket)}
      end)

    {:cont, socket}
  end

  defp put_title(socket) do
    case title(socket.assigns[:live_action]) do
      nil -> socket
      title -> assign(socket, :page_title, title)
    end
  end

  @doc """
  The title for a live action, or `nil` if it has none.

  Public so `auth_titles_test.exs` can enumerate the auth session's routes and
  assert each one resolves — the check that keeps a new auth page from silently
  reintroducing #559.
  """
  @spec title(atom() | nil) :: String.t() | nil
  # `/sign-in` and `/magic_link/:token` share this action, and "Sign in" is the
  # right name for both — one asks for a password, the other has already been
  # handed a token, but the page the visitor is on is the same one.
  def title(:sign_in), do: gettext("Sign in")
  def title(:register), do: gettext("Create an account")
  # Also shared: `/reset` requests the link, `/password-reset/:token` sets the
  # new password. Both are "resetting your password" from the visitor's side.
  def title(:reset), do: gettext("Reset your password")
  def title(:confirm), do: gettext("Confirm your email")
  def title(:sign_out), do: gettext("Sign out")
  def title(_unmapped), do: nil
end
