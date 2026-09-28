defmodule KilnCMSWeb.EditorAliasController do
  @moduledoc """
  Permanent redirects from the pre-generic editor URLs `/editor/pages/:id` and
  `/editor/posts/:id` to `/editor/content/page/:id` and
  `/editor/content/post/:id`.

  The two aliases were editor routes until 0.12 deprecated them (#1538) and
  1.0 removed them (#1543). Nothing in the core has linked to them since, but
  bookmarks and review-request mail sent by older releases still do, and a 404
  there would read as "the page is gone". A `301` costs one route each and
  answers without touching the record: the editor route it points at does the
  sign-in, the editor gate and the lookup, exactly as for any other visit.

  Not a covered surface (`docs/overlay-contract.md`): a courtesy for old links,
  which a later major may drop.
  """
  use KilnCMSWeb, :controller

  def page(conn, %{"id" => id}), do: moved_permanently(conn, ~p"/editor/content/page/#{id}")
  def post(conn, %{"id" => id}), do: moved_permanently(conn, ~p"/editor/content/post/#{id}")

  defp moved_permanently(conn, path) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: path)
  end
end
