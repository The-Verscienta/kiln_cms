defmodule KilnCMSWeb.TranslationsExportControllerTest do
  @moduledoc """
  The XLIFF download (#502): editor-gated (like the analytics export, and for
  the same reason — the dashboard it downloads from is editor-visible), scoped
  to the signed-in actor, and strict about its query string.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "xliff-export-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp slug, do: "xec-#{System.unique_integer([:positive])}"

  defp page(actor) do
    CMS.create_page!(
      %{
        title: "Downloadable",
        slug: slug(),
        locale: "en",
        blocks: [%{"_type" => "heading", "text" => "Chapter"}]
      },
      actor: actor
    )
  end

  defp get_export(conn, params),
    do: get(conn, ~p"/editor/translations/export.xlf?#{params}")

  test "an editor downloads an XLIFF attachment", %{conn: conn} do
    editor = authed_user(:editor)
    page = page(editor)

    conn =
      conn
      |> log_in(editor)
      |> get_export(%{"target" => "fr", "record" => ["page:#{page.id}"]})

    assert response_content_type(conn, :xlf) =~ "application/xliff+xml"

    assert ["attachment; filename=\"" <> rest] = get_resp_header(conn, "content-disposition")
    assert rest == "#{page.slug}-en-fr.xlf\""

    body = response(conn, 200)
    assert body =~ ~s(srcLang="en" trgLang="fr")
    assert body =~ "Downloadable"
    assert body =~ "Chapter"
  end

  test "a batch produces one file per record, named for the pair", %{conn: conn} do
    editor = authed_user(:editor)
    a = page(editor)
    b = page(editor)

    conn =
      conn
      |> log_in(editor)
      |> get_export(%{"target" => "es", "record" => ["page:#{a.id}", "page:#{b.id}"]})

    assert ["attachment; filename=\"en-es.xlf\""] = get_resp_header(conn, "content-disposition")

    body = response(conn, 200)
    assert body =~ ~s(original="page/#{a.slug}")
    assert body =~ ~s(original="page/#{b.slug}")
  end

  test "a signed-in viewer is refused", %{conn: conn} do
    reader = authed_user(:viewer)
    editor = authed_user(:editor)
    page = page(editor)

    conn =
      conn
      |> log_in(reader)
      |> get_export(%{"target" => "fr", "record" => ["page:#{page.id}"]})

    assert json_response(conn, 403) == %{"error" => "editor_required"}
  end

  test "bad query strings are 400s, not 500s", %{conn: conn} do
    editor = authed_user(:editor)
    page = page(editor)
    conn = log_in(conn, editor)

    assert %{"error" => "target locale required"} =
             conn |> get_export(%{"record" => ["page:#{page.id}"]}) |> json_response(400)

    assert %{"error" => "no records selected"} =
             conn |> get_export(%{"target" => "fr"}) |> json_response(400)

    assert %{"error" => "unknown locale: zz"} =
             conn
             |> get_export(%{"target" => "zz", "record" => ["page:#{page.id}"]})
             |> json_response(400)

    assert %{"error" => "malformed record: nonsense"} =
             conn
             |> get_export(%{"target" => "fr", "record" => ["nonsense"]})
             |> json_response(400)

    # A bookmarkable `?record[x]=1` decodes to a map, not a list (#764).
    assert %{"error" => "no records selected"} =
             conn
             |> get_export(%{"target" => "fr", "record" => %{"x" => "1"}})
             |> json_response(400)

    # An unknown content type raises out of the dispatcher; it must not 500, and
    # it must say which of the fifty ticked rows was the problem.
    assert %{"error" => "unknown content type: nope"} =
             conn
             |> get_export(%{"target" => "fr", "record" => ["nope:#{page.id}"]})
             |> json_response(400)
  end

  test "a record the actor cannot read is not exported", %{conn: conn} do
    editor = authed_user(:editor)
    page = page(editor)

    conn =
      conn
      |> log_in(authed_user(:editor))
      |> get_export(%{"target" => "fr", "record" => ["page:#{Ash.UUID.generate()}"]})

    assert %{"error" => error} = json_response(conn, 400)
    assert error =~ "record not found"
    refute error =~ page.slug
  end
end
