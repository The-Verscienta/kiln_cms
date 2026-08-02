defmodule KilnCMSWeb.SessionCookieTest do
  @moduledoc """
  Pins the production session cookie (#686), which no test build ever emits.

  `:secure_session_cookie` is compile-time and only `config/prod.exs` sets it,
  so a test that reads the *running* endpoint's cookie asserts the dev shape and
  passes no matter what a release would ship. Everything here therefore either
  constructs `options(true)` explicitly, or reads `config/prod.exs` the way a
  release does — the same `Config.Reader` approach as
  `KilnCMS.Config.RuntimeProvenanceTest`, and for the same reason: nothing else
  in the suite evaluates that file.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.Endpoint
  alias KilnCMSWeb.SessionCookie

  doctest KilnCMSWeb.SessionCookie

  @config Path.expand("../../config/config.exs", __DIR__)

  # A `Cookie` header a browser would actually send, so the assertions are
  # against emitted bytes rather than against the options keyword list. Plug
  # decides how the options are serialised, and `__Host-` is a rule about the
  # serialised form.
  defp set_cookie(opts) do
    :get
    |> Plug.Test.conn("/")
    |> Map.put(:secret_key_base, String.duplicate("kiln", 16))
    |> Plug.Session.call(Plug.Session.init(opts))
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.put_session(:user, "someone")
    |> Plug.Conn.send_resp(200, "")
    |> Plug.Conn.get_resp_header("set-cookie")
    |> hd()
  end

  describe "the production cookie" do
    test "is named with the __Host- prefix" do
      assert SessionCookie.options(true)[:key] == "__Host-_kiln_cms_key"
    end

    test "satisfies every precondition the browser enforces for that prefix" do
      header = set_cookie(SessionCookie.options(true))

      # A browser rejects a `__Host-` cookie outright unless all three hold, so
      # a violation is not a weakening — it is every session silently discarded.
      assert header =~ ~r/^__Host-_kiln_cms_key=/
      assert header =~ "; path=/;"
      assert header =~ "; secure"
      refute header =~ "domain="
    end

    test "is still signed, encrypted, http-only and SameSite=Lax" do
      opts = SessionCookie.options(true)
      header = set_cookie(opts)

      assert opts[:store] == :cookie
      assert opts[:signing_salt]
      assert opts[:encryption_salt]
      assert header =~ "; HttpOnly"
      assert header =~ "; SameSite=Lax"
    end

    test "is what config/prod.exs actually asks for" do
      # The flag is the whole control: unset it and a release ships a cookie
      # that is neither `Secure` nor prefixed, with every other test still green
      # because they all run in an env where it is legitimately off.
      assert prod_secure_session_cookie() == true
      assert SessionCookie.options(prod_secure_session_cookie())[:key] == "__Host-_kiln_cms_key"
    end

    defp prod_secure_session_cookie do
      @config
      |> Config.Reader.read!(env: :prod)
      |> get_in([:kiln_cms, :secure_session_cookie])
    end
  end

  describe "the dev, test and e2e cookie" do
    test "keeps the bare name, because the prefix needs Secure" do
      opts = SessionCookie.options(false)

      refute String.starts_with?(opts[:key], "__Host-")
      refute opts[:secure]
    end

    test "still pins Path=/ and no Domain, so the prefix can be turned on freely" do
      opts = SessionCookie.options(false)

      assert opts[:path] == "/"
      refute Keyword.has_key?(opts, :domain)
    end
  end

  describe "a non-boolean :secure_session_cookie" do
    test "is refused by name rather than coerced" do
      # "false" is truthy, so coercing would mark the cookie `Secure` under the
      # unprefixed name — the one combination the prefix exists to rule out.
      #
      # The value comes through a config read rather than as a literal because
      # the compiler's type checker knows `options/1` only returns for a boolean
      # and rejects a literal non-boolean call outright. That static check is
      # welcome but is not the protection under test: the real value arrives
      # from `Application.compile_env/3` as an opaque term, exactly like this.
      assert_raise ArgumentError, ~r/:secure_session_cookie/, fn ->
        SessionCookie.options(not_a_boolean())
      end
    end

    defp not_a_boolean do
      Application.get_env(:kiln_cms, :__unset_for_this_test__, "false")
    end
  end

  describe "the endpoint" do
    test "takes its whole session cookie from the rule rather than restating it" do
      running = Endpoint.session_options()

      assert running == SessionCookie.options(running[:secure])
    end
  end
end
