defmodule KilnCMSWeb.RequestRedactionTest do
  @moduledoc """
  Which request paths carry a credential, and what they look like once it is
  taken out (#2449). The request line itself is covered end to end in
  `KilnCMSWeb.RequestLogTest`.
  """
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2]

  alias KilnCMSWeb.RequestRedaction

  # Every route whose path carries a credential, and what that credential does.
  # Adding a token route to the router fails the drift test below until it is
  # listed here — on purpose: the new route then gets a row in the log test too.
  @secret_routes %{
    "/auth/invite/:invite_token" => "accepts a site invitation",
    "/auth/unlock/:unlock_token" => "unlocks sign-in",
    "/magic_link/:token" => "signs in",
    "/password-reset/:token" => "resets a password",
    "/confirm_new_user/:token" => "confirms an account",
    "/preview/:token" => "reads a draft",
    "/preview/release/:token" => "previews a content release",
    "/preview/:token/live" => "reads a draft, live",
    "/newsletter/unsubscribe/:token" => "acts on a subscriber",
    "/newsletter/confirm/:token" => "completes a double opt-in"
  }

  # Route parameters whose name looks credential-shaped but is not a secret.
  @not_secret %{
    "key" => "`/api/menus/:key` names a public menu"
  }

  @credential_shaped ~r/token|secret|key|sig|code|hash|grant|nonce/i

  defp token, do: "T#{System.unique_integer([:positive])}secret"

  describe "redact_path/1" do
    for {path, expected} <- [
          {"/auth/invite/TOKEN", "/auth/invite/[FILTERED]"},
          {"/auth/unlock/TOKEN", "/auth/unlock/[FILTERED]"},
          {"/magic_link/TOKEN", "/magic_link/[FILTERED]"},
          {"/password-reset/TOKEN", "/password-reset/[FILTERED]"},
          {"/confirm_new_user/TOKEN", "/confirm_new_user/[FILTERED]"},
          {"/preview/TOKEN", "/preview/[FILTERED]"},
          # Both `/preview/:token` and `/preview/release/:token` match, and
          # both apply: `release` is redacted along with the token.
          {"/preview/release/TOKEN", "/preview/[FILTERED]/[FILTERED]"},
          {"/preview/TOKEN/live", "/preview/[FILTERED]/live"},
          {"/newsletter/unsubscribe/TOKEN", "/newsletter/unsubscribe/[FILTERED]"},
          {"/newsletter/confirm/TOKEN", "/newsletter/confirm/[FILTERED]"},
          # A locale prefix, which `SetLocale` has not stripped yet when the
          # request line is written.
          {"/fr/magic_link/TOKEN", "/fr/magic_link/[FILTERED]"},
          {"/fr/preview/release/TOKEN", "/fr/preview/[FILTERED]/[FILTERED]"},
          # Any first segment, configured locale or not.
          {"/xx/magic_link/TOKEN", "/xx/magic_link/[FILTERED]"},
          # A mangled link: trailing segments are kept, the token is not.
          {"/magic_link/TOKEN/x", "/magic_link/[FILTERED]/x"},
          # Empty segments are dropped, as the router drops them.
          {"//magic_link/TOKEN", "/magic_link/[FILTERED]"}
        ] do
      @path path
      @expected expected
      test "#{path} → #{expected}" do
        token = token()
        path = String.replace(@path, "TOKEN", token)

        assert RequestRedaction.redact_path(path) == @expected
        assert RequestRedaction.secret?(path)
        refute RequestRedaction.redact_path(path) =~ token
      end
    end

    for path <- [
          "/",
          "/sitemap.xml",
          "/fr/blog",
          "/blog/a-post/",
          "/api/menus/main",
          "/media/0b8c7f0e-0000-4000-8000-000000000000/download",
          "/preview",
          "/magic_link",
          "/sign-in/unlock"
        ] do
      @path path
      test "#{path} comes back byte-identical" do
        assert RequestRedaction.redact_path(@path) == @path
        assert RequestRedaction.redact(@path) == :unchanged
        refute RequestRedaction.secret?(@path)
      end
    end
  end

  describe "a conn" do
    test "is matched on its decoded path_info and rebuilt from it" do
      token = token()

      conn = %{
        conn(:get, "/")
        | request_path: "//magic%5Flink/#{token}",
          path_info: ["magic%5Flink", token]
      }

      assert RequestRedaction.redact_path(conn) == "/magic%5Flink/[FILTERED]"
    end

    test "with no secret returns its request_path untouched" do
      conn = conn(:get, "/blog//a%20post/")

      assert RequestRedaction.redact(conn) == :unchanged
      assert RequestRedaction.redact_path(conn) == "/blog//a%20post/"
    end

    test "a malformed escape is compared as written, not raised on" do
      conn = %{
        conn(:get, "/")
        | request_path: "/magic_link/%zz",
          path_info: ["magic_link", "%zz"]
      }

      assert RequestRedaction.redact_path(conn) == "/magic_link/[FILTERED]"
    end
  end

  describe "the router-derived rule" do
    test "covers exactly the routes in the table" do
      assert {:ok, routes} = RequestRedaction.secret_routes()
      assert MapSet.new(routes) == MapSet.new(Map.keys(@secret_routes))
    end

    test "every credential-shaped route parameter is redacted or allowed with a reason" do
      unaccounted =
        for %{path: path} <- Phoenix.Router.routes(KilnCMSWeb.Router),
            segment <- String.split(path, "/", trim: true),
            [_, name] <- [Regex.run(~r/[:*](\w+)$/, segment)],
            name =~ @credential_shaped,
            not RequestRedaction.credential_param?(name),
            not Map.has_key?(@not_secret, name),
            uniq: true,
            do: {path, name}

      assert unaccounted == []
    end

    test "names a parameter a credential by `token` or `secret`, in any case" do
      for name <- ~w(token invite_token unlock_token TOKEN client_secret Secret),
          do: assert(RequestRedaction.credential_param?(name), name)

      for name <- ~w(id slug key locale type ops),
          do: refute(RequestRedaction.credential_param?(name), name)
    end
  end
end
