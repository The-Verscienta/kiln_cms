defmodule KilnCMSWeb.EnumerationAuthorRoutesTest do
  @moduledoc """
  No public route names an account, so none can say whether an address has one
  (#2255, surface 8).

  A byline is a `Person` entry the editors flag on a field
  (`KilnCMS.Firing.Bylines`), not a lookup of the console `User`; the console
  user's `name` is the only thing the public pages and feeds ever take from the
  account, and never its address. Three checks pin that down:

    * the router has no route that serves accounts by name, address or slug
      outside the sign-in flow and the authenticated console;
    * the one public endpoint that takes an `acct:` handle (WebFinger) answers
      a registered address and an unregistered one with the same 404;
    * a published post by a known account carries the account's name on no
      public surface in the form of an address — HTML, feeds, the JSON:API.

  `async: false`: the WebFinger case turns federation on, a VM-global switch.
  """
  use KilnCMSWeb.ConnCase, async: false

  import KilnCMS.EnumerationAssertions

  alias KilnCMS.CMS

  # Every route whose path or controller speaks of accounts, and why each is
  # not a public lookup. A new match fails the test until someone has decided.
  @account_routes %{
    # Authenticated console screens (login required by their live_session).
    "/account" => :console,
    "/membership" => :console,
    "/editor/team" => :console,
    "/editor/accounts" => :console,
    "/editor/accounts/:id" => :console,
    "/editor/account/export.json" => :console,
    # The authentication flow: acts on the address it is handed, never searches.
    "/confirm_new_user/:token" => :auth_flow,
    "/auth/user/confirm_new_user" => :auth_flow,
    "/auth/user/sso" => :auth_flow,
    "/auth/user/sso/callback" => :auth_flow,
    "/auth/user/magic_link" => :auth_flow,
    "/auth/user/magic_link/request" => :auth_flow,
    "/auth/user/password/sign_in_with_token" => :auth_flow,
    "/auth/user/password/register" => :auth_flow,
    "/auth/user/password/sign_in" => :auth_flow,
    "/auth/user/password/reset_request" => :auth_flow,
    "/auth/user/password/reset" => :auth_flow
  }

  @account_words ~r{user|author|profile|member|people|byline|account|team}i

  test "no route serves accounts except the console and the sign-in flow" do
    paths =
      KilnCMSWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(& &1.path)
      |> Enum.filter(&Regex.match?(@account_words, &1))
      |> Enum.reject(&String.starts_with?(&1, "/dev/"))
      |> Enum.uniq()

    assert paths -- Map.keys(@account_routes) == []
  end

  describe "WebFinger" do
    setup do
      KilnCMS.FederationFixtures.enable_deployment!()

      KilnCMS.FederationFixtures.enable_site!(KilnCMS.Accounts.default_org_id(),
        origin: "http://www.example.com"
      )

      :ok
    end

    test "a registered address and an unregistered one are both a plain 404", %{conn: conn} do
      known = "enum-wf-#{System.unique_integer([:positive])}@example.com"
      unknown = "enum-wf-nobody-#{System.unique_integer([:positive])}@example.com"

      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: known,
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :editor
      })

      ask = fn email ->
        get(conn, "/.well-known/webfinger?resource=#{URI.encode_www_form("acct:" <> email)}")
      end

      seen =
        assert_indistinguishable(fn -> ask.(known) end, fn -> ask.(unknown) end, [known, unknown])

      assert seen.status == 404

      # Control: federation is live, so the 404 is the handle not matching, not
      # the endpoint being off.
      assert conn
             |> get("/.well-known/webfinger?resource=acct:kiln@www.example.com")
             |> response(200)
    end
  end

  describe "published content by a known account" do
    test "carries no address on any public surface", %{conn: conn} do
      email = "enum-byline-#{System.unique_integer([:positive])}@example.com"

      author =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: email,
          name: "Enum Byline",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :admin
        })

      post =
        CMS.create_post!(
          %{title: "Public byline", slug: "enum-byline-#{System.unique_integer([:positive])}"},
          actor: author
        )
        |> then(&CMS.publish_post!(&1, %{}, actor: author))

      # Firing is async on publish; run the enqueued worker so the artifacts exist.
      KilnCMS.DataCase.drain_oban()

      for path <- [
            "/blog/#{post.slug}",
            "/feed.xml",
            "/feed.json",
            "/posts/feed.xml",
            "/api/content/post/#{post.slug}?surface=json_ld",
            "/api/json/posts/#{post.id}"
          ] do
        conn = get(conn, path)
        assert conn.status == 200, "#{path} answered #{conn.status}"
        refute conn.resp_body =~ email, "#{path} carries the account's address"
      end

      # Control: the page does name the author, so the missing address is a choice.
      assert conn |> get("/blog/#{post.slug}") |> response(200) =~ "Enum Byline"

      # The positive control: the post is really served on a surface above.
      assert conn |> get("/api/json/posts/#{post.id}") |> response(200) =~ post.slug
    end
  end
end
