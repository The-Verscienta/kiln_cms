defmodule KilnCMSWeb.JsBundleTest do
  @moduledoc """
  Which script a page loads (#2402): `public.js` on the signed-out content
  pages whose controllers opt in, `app.js` on everything else —
  `KilnCMSWeb.Layouts.js_bundle_path/1`.

  The cases that matter most are the refusals: a LiveView in the same
  `:delivery` scope (`/membership`), a page with a flash, and a build with no
  `public.js`. Any of them on `public.js` is a page whose controls do nothing.

  `async: false`: whether `public.js` was built is one `:persistent_term`
  answer for the whole VM, forced here because `mix test` builds no assets,
  and `KilnCMS.ChallengeFixtures.enable!/1` writes application env and an OS
  variable.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import KilnCMS.ChallengeFixtures

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post
  alias KilnCMS.FormFixtures
  alias KilnCMSWeb.Layouts

  setup do
    KilnCMS.Cache.bust_published()
    Layouts.put_public_bundle_built(true)
    on_exit(fn -> Layouts.put_public_bundle_built(nil) end)
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  # The one bundle a page loads. Both, or neither, is a failure of its own.
  defp bundle(html) do
    case {html =~ ~s(src="/assets/js/public.js), html =~ ~s(src="/assets/js/app.js)} do
      {true, false} -> :public
      {false, true} -> :app
      other -> flunk("expected exactly one bundle, got #{inspect(other)}")
    end
  end

  defp signed_in(conn, role) do
    email = "bundle-#{role}-#{uniq()}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
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
  end

  describe "signed-out content pages load public.js" do
    test "a published page, a post, the blog index and search" do
      page =
        Ash.Seed.seed!(Page, %{title: "Bundle page", slug: "jb-#{uniq()}", state: :published})

      post =
        Ash.Seed.seed!(Post, %{
          title: "Bundle post",
          slug: "jb-#{uniq()}",
          state: :published,
          published_at: DateTime.utc_now()
        })

      for path <- ["/#{page.slug}", "/blog/#{post.slug}", "/blog", "/search?q=bundle"] do
        assert build_conn() |> get(path) |> html_response(200) |> bundle() == :public, path
      end
    end

    test "the stock home page, with no flash" do
      assert build_conn() |> get(~p"/") |> html_response(200) |> bundle() == :public
    end

    test "a signed-in reader on a delivered page gets it too" do
      page =
        Ash.Seed.seed!(Page, %{title: "Bundle page", slug: "jb-#{uniq()}", state: :published})

      html = build_conn() |> signed_in(:editor) |> get("/#{page.slug}") |> html_response(200)
      assert bundle(html) == :public
    end

    test "the passphrase lock page and the delivery 404" do
      page =
        Ash.Seed.seed!(Page, %{
          title: "Locked",
          slug: "jb-#{uniq()}",
          state: :published,
          access_password_hash: Bcrypt.hash_pwd_salt("a-shared-secret")
        })

      assert build_conn() |> get("/#{page.slug}") |> html_response(401) |> bundle() == :public

      assert build_conn() |> get("/jb-missing-#{uniq()}") |> html_response(404) |> bundle() ==
               :public
    end
  end

  describe "a form's pages load public.js, which mounts the challenge" do
    setup do
      enable!()
      %{form: FormFixtures.form!(%{challenge: :always})}
    end

    test "the form's own page", %{form: form} do
      html = build_conn() |> unique_ip() |> get("/forms/#{form.slug}") |> html_response(200)

      assert html =~ "data-kiln-challenge"
      assert bundle(html) == :public
    end

    test "a content page placing a challenge-enabled form", %{form: form} do
      page =
        Ash.Seed.seed!(Page, %{
          title: "Form page",
          slug: "jb-#{uniq()}",
          state: :published,
          blocks:
            KilnCMS.TypedFixtures.typed_blocks([
              %{type: :form, content: form.slug, data: %{"form_slug" => form.slug}, order: 0}
            ])
        })

      html = build_conn() |> get("/#{page.slug}") |> html_response(200)

      assert html =~ "data-kiln-challenge"
      assert bundle(html) == :public
    end

    test "the thank-you page and the refused re-render", %{form: form} do
      thanks =
        build_conn()
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "a@b.co", "_kiln_challenge" => "pass"})

      assert html_response(thanks, 200) =~ "Merci!"
      assert bundle(html_response(thanks, 200)) == :public

      refused =
        build_conn()
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "a@b.co", "_kiln_challenge" => "fail"})

      html = html_response(refused, 422)
      assert html =~ "data-kiln-challenge"
      assert bundle(html) == :public
    end

    test "the embed loads neither: it has its own mount script", %{form: form} do
      html = build_conn() |> unique_ip() |> get("/forms/#{form.slug}/embed") |> html_response(200)

      assert html =~ "challenge_static.js"
      refute html =~ "/assets/js/public.js"
      refute html =~ "/assets/js/app.js"
    end
  end

  describe "the newsletter pages load public.js" do
    test "confirm and unsubscribe" do
      sub =
        KilnCMS.Newsletter.subscribe!(%{email: "jb-#{uniq()}@example.com"}, authorize?: false)

      confirm = build_conn() |> get(~p"/newsletter/confirm/#{sub.confirm_token}")
      assert confirm |> html_response(200) |> bundle() == :public

      unsubscribe = build_conn() |> get(~p"/newsletter/unsubscribe/#{sub.unsubscribe_token}")
      assert unsubscribe |> html_response(200) |> bundle() == :public
    end
  end

  describe "everything else keeps app.js" do
    # The leak case: a LiveView in the same `:delivery` scope as the content
    # routes. A pipeline assign would have reached it through `live_render/3`.
    test "MembershipLive" do
      assert build_conn() |> get(~p"/membership") |> html_response(200) |> bundle() == :app
    end

    test "the sign-in LiveView" do
      assert build_conn() |> get(~p"/sign-in") |> html_response(200) |> bundle() == :app
    end

    test "the console" do
      conn = build_conn() |> signed_in(:admin) |> get(~p"/editor")
      assert conn |> html_response(200) |> bundle() == :app
    end

    # `Layouts.flash_group/1` closes through a JS command and a hook, which
    # only app.js carries — `/` is where sign-out lands with its flash.
    test "the stock home page with a flash" do
      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{"phoenix_flash" => %{"info" => "Signed out."}})
        |> get(~p"/")

      html = html_response(conn, 200)
      assert html =~ "Signed out."
      assert bundle(html) == :app
    end

    test "every opted-in page, when public.js was not built" do
      Layouts.put_public_bundle_built(false)

      page =
        Ash.Seed.seed!(Page, %{title: "Bundle page", slug: "jb-#{uniq()}", state: :published})

      assert build_conn() |> get("/#{page.slug}") |> html_response(200) |> bundle() == :app
      assert build_conn() |> get(~p"/") |> html_response(200) |> bundle() == :app
    end
  end

  describe "js_bundle_path/1" do
    test "public.js only for an opted-in dead render with no flash" do
      assert Layouts.js_bundle_path(%{js_bundle: :public, flash: %{}}) =~ "/assets/js/public.js"
      assert Layouts.js_bundle_path(%{js_bundle: :public}) =~ "/assets/js/public.js"
    end

    test "app.js for anything else" do
      for assigns <- [
            %{},
            %{flash: %{}},
            %{js_bundle: :app},
            %{js_bundle: :public, live_module: KilnCMSWeb.MembershipLive},
            %{js_bundle: :public, flash: %{"info" => "Saved"}}
          ] do
        assert Layouts.js_bundle_path(assigns) =~ "/assets/js/app.js", inspect(assigns)
      end
    end

    test "app.js when public.js was not built; only a hit is memoized" do
      Layouts.put_public_bundle_built(false)
      assert Layouts.js_bundle_path(%{js_bundle: :public}) =~ "/assets/js/app.js"

      # Forgotten, it is looked up on disk once and then kept.
      Layouts.put_public_bundle_built(nil)

      built? =
        :kiln_cms
        |> Application.app_dir("priv/static/assets/js/public.js")
        |> File.exists?()

      assert Layouts.public_bundle_built?() == built?
      # A hit is kept for the life of the VM; a miss is looked up again next
      # time, so a dev server that boots before its watcher wrote the file
      # still picks it up.
      assert :persistent_term.get({Layouts, :public_bundle_built?}, nil) ==
               if(built?, do: true, else: nil)
    end
  end
end
