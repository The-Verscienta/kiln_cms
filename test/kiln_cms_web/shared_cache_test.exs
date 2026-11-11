defmodule KilnCMSWeb.SharedCacheTest do
  @moduledoc """
  A public HTML response a shared cache may store renders nothing from the
  session (#2630, `KilnCMSWeb.SharedCache`): no CSRF token, no signed-in
  user's links, no session cookie. The test of it is the one the issue asked
  for: the same body, signed in and signed out.

  The private pages (the passphrase lock page) keep their token, which their
  form needs.

  `async: false`: these read the shared delivery cache.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post
  alias KilnCMS.FormFixtures
  alias KilnCMSWeb.Layouts
  alias KilnCMSWeb.SharedCache

  setup do
    KilnCMS.Cache.bust_published()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  # A real sign-in, so `:load_from_session` resolves the user and the
  # delivery path sees a `current_user`. The session is stored by one request
  # and carried as a cookie into the next (`recycle/1`), as a browser would,
  # so the request under test does not itself write a fresh session.
  defp signed_in(conn) do
    email = "shared-cache-#{uniq()}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })

    {:ok, user} =
      AshAuthentication.Strategy.action(
        AshAuthentication.Info.strategy!(User, :password),
        :sign_in,
        %{"email" => email, "password" => "password123456"},
        []
      )

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
    |> get("/account")
    |> recycle()
  end

  # What two renders of the same page may differ by without either coming from
  # the session: the per-request CSP nonce, and a form's signed render time
  # (its too-fast-to-be-human check).
  defp normalize(html) do
    html
    |> String.replace(~r/nonce="[^"]*"/, ~s(nonce=""))
    |> String.replace(~r/(name="_kiln_rendered_at" value=)"[^"]*"/, ~s(\\1""))
  end

  defp assert_shared_and_session_free(path) do
    anonymous = get(build_conn(), path)
    member = get(signed_in(build_conn()), path)

    for conn <- [anonymous, member] do
      assert [cache_control] = get_resp_header(conn, "cache-control")
      assert cache_control =~ "public"

      html = html_response(conn, 200)
      refute html =~ ~s(name="csrf-token")
      refute html =~ "_csrf_token"
      refute html =~ ~s(href="/sign-out")
      refute html =~ ~s(href="/account")
      assert get_resp_header(conn, "set-cookie") == []
    end

    assert normalize(html_response(member, 200)) == normalize(html_response(anonymous, 200))
  end

  describe "public delivery HTML" do
    test "a published page with a form and a newsletter signup" do
      form = FormFixtures.form!(%{})

      page =
        Ash.Seed.seed!(Page, %{
          title: "Shared page",
          slug: "sc-#{uniq()}",
          state: :published,
          blocks:
            KilnCMS.TypedFixtures.typed_blocks([
              %{type: :heading, content: "Body", data: %{"level" => 2}, order: 0},
              %{
                type: :form,
                content: form.slug,
                data: %{"form_slug" => form.slug},
                order: 1
              },
              %{type: :newsletter_signup, content: "Subscribe", order: 2}
            ])
        })

      assert_shared_and_session_free("/#{page.slug}")
    end

    test "a published post and the blog index" do
      post =
        Ash.Seed.seed!(Post, %{
          title: "Shared post",
          slug: "sc-#{uniq()}",
          state: :published,
          published_at: DateTime.utc_now()
        })

      assert_shared_and_session_free("/blog/#{post.slug}")
      assert_shared_and_session_free("/blog")
    end

    test "the standalone form page" do
      form = FormFixtures.form!(%{})
      assert_shared_and_session_free("/forms/#{form.slug}")
    end

    test "a page a conditional request revalidates still 304s" do
      page = Ash.Seed.seed!(Page, %{title: "Etag", slug: "sc-#{uniq()}", state: :published})

      conn = get(build_conn(), "/#{page.slug}")
      [etag] = get_resp_header(conn, "etag")

      revalidated =
        build_conn() |> put_req_header("if-none-match", etag) |> get("/#{page.slug}")

      assert revalidated.status == 304
    end
  end

  describe "private pages keep the token" do
    test "the passphrase lock page carries its CSRF token, signed out and in" do
      page =
        Ash.Seed.seed!(Page, %{
          title: "Locked",
          slug: "sc-#{uniq()}",
          state: :published,
          access_password_hash: Bcrypt.hash_pwd_salt("a-shared-secret")
        })

      for conn <- [build_conn(), signed_in(build_conn())] do
        conn = get(conn, "/#{page.slug}")
        assert get_resp_header(conn, "cache-control") == ["private, no-store"]
        html = html_response(conn, 401)
        assert html =~ ~s(name="csrf-token")
        assert html =~ ~s(name="_csrf_token")
      end
    end
  end

  describe "put_public/2 and shared?/1" do
    test "put_public clears the signed-in user a template could pass on" do
      conn =
        build_conn()
        |> Plug.Conn.assign(:current_user, %{id: "someone"})
        |> SharedCache.put_public()

      assert conn.assigns.current_user == nil
      assert SharedCache.shared?(conn)
    end

    test "shared? reads the public directive, not a substring" do
      shared? = fn value ->
        build_conn() |> Plug.Conn.put_resp_header("cache-control", value) |> SharedCache.shared?()
      end

      assert shared?.("public, max-age=60")
      assert shared?.("max-age=60, Public")
      refute shared?.("private, no-store")
      refute shared?.("no-cache, x-not-public")
      refute SharedCache.shared?(nil)
    end

    test "the root layout asks for no token on a shared response" do
      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> SharedCache.put_public()

      assert Layouts.csrf_token(%{conn: conn}) == nil
    end
  end
end
