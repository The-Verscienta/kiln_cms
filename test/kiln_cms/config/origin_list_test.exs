defmodule KilnCMS.Config.OriginListTest do
  @moduledoc """
  The shared origin-allowlist parser (#651), and the two callers' differing
  answers to what a malformed entry costs.

  `EMBED_ORIGINS` and `CORS_ORIGINS` were two hand-rolled copies of the same
  split/trim/wildcard contract, already diverging: `Embed` grew entry validation
  in #562 and `CORS` did not, so the "is `*` mixed into a list handled?"
  question had never been asked on the CORS side. `form_embed_test.exs` was the
  only `parse_env` coverage in the repo.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias KilnCMS.Config.OriginList
  alias KilnCMSWeb.CORS
  alias KilnCMSWeb.Embed

  doctest KilnCMS.Config.OriginList

  describe "the shared contract" do
    test "unset and blank close" do
      assert OriginList.parse(nil) == []
      assert OriginList.parse("") == []
      assert OriginList.parse("   ") == []
      # A `FOO=` artifact of .env files and `docker run --env-file`.
      assert OriginList.parse(",, ,") == []
    end

    test "a lone wildcard opens, whitespace and all" do
      assert OriginList.parse("*") == :all
      assert OriginList.parse("  *  ") == :all
    end

    test "entries are split, trimmed, and blanks dropped" do
      assert OriginList.parse("https://a.test, ,  https://b.test ,") == [
               "https://a.test",
               "https://b.test"
             ]
    end

    test "without a validator every non-blank entry is kept" do
      assert OriginList.parse("anything at all,https://b.test") == [
               "anything at all",
               "https://b.test"
             ]
    end
  end

  describe ":on_invalid" do
    defp reject_b(entry), do: entry != "bad"

    test ":discard_all drops the whole value and names the entry" do
      warning =
        capture_io(:stderr, fn ->
          assert OriginList.parse("https://a.test,bad",
                   name: "SOME_ORIGINS",
                   validator: &reject_b/1
                 ) == []
        end)

      assert warning =~ "SOME_ORIGINS"
      assert warning =~ ~s("bad")
      # The point of all-or-nothing: it says it did not apply the good half.
      assert warning =~ "in part"
    end

    # Applies the value UNCHANGED, not "minus the bad ones". Under `:keep` the
    # validator is a heuristic about what browsers send, and dropping an entry on
    # a heuristic is the same outage the mode exists to prevent, arrived at
    # quietly — the operator's only notice is on stderr, which per #634 never
    # reaches Logger or Sentry.
    test ":keep applies the whole value and still names the entry" do
      warning =
        capture_io(:stderr, fn ->
          assert OriginList.parse("https://a.test,bad",
                   name: "SOME_ORIGINS",
                   validator: &reject_b/1,
                   on_invalid: :keep
                 ) == ["https://a.test", "bad"]
        end)

      assert warning =~ "SOME_ORIGINS"
      assert warning =~ ~s("bad")
      assert warning =~ "never match"
      assert warning =~ "nothing was dropped"
    end

    # Checked on every call, not only on the branch where an entry happens to be
    # invalid. Otherwise a third caller with a typo boots cleanly for as long as
    # its values are good and raises on the day someone fat-fingers an origin.
    test "a bad option is caught on a value that is entirely valid" do
      assert_raise KeyError, fn ->
        OriginList.parse("https://a.test", validator: &reject_b/1)
      end

      assert_raise CaseClauseError, fn ->
        OriginList.parse("https://a.test",
          name: "SOME_ORIGINS",
          validator: &reject_b/1,
          on_invalid: :kepe
        )
      end
    end

    test "no validator means no options to get wrong" do
      assert OriginList.parse("bad") == ["bad"]
    end

    test "a fully valid list warns about nothing" do
      warning =
        capture_io(:stderr, fn ->
          assert OriginList.parse("https://a.test", name: "SOME_ORIGINS", validator: &reject_b/1) ==
                   ["https://a.test"]
        end)

      assert warning == ""
    end
  end

  # The half of #651 that had no coverage at all: the CORS parser.
  describe "CORS_ORIGINS" do
    test "wildcard, allowlist and blank behave as before" do
      assert CORS.parse_env("*") == :all
      assert CORS.parse_env(nil) == []
      assert CORS.parse_env("") == []

      assert CORS.parse_env("https://a.test, https://b.test") == [
               "https://a.test",
               "https://b.test"
             ]
    end

    test "an origin that can never match is named, and nothing is dropped" do
      value = "https://a.test/,https://b.test,acme.test,*,https://c.test/x"

      warning =
        capture_io(:stderr, fn ->
          # Every one of these is a real mistake a browser's `Origin` header can
          # never equal: a trailing slash, a path, a bare host, and a `*` mixed
          # into a list. Named, and left in place — see the `:keep` test above.
          assert CORS.parse_env(value) == String.split(value, ",")
        end)

      assert warning =~ "CORS_ORIGINS"
      assert warning =~ ~s("https://a.test/")
      assert warning =~ ~s("acme.test")
      assert warning =~ ~s("*")
    end

    # The regression this pair guards: a validator that only accepted http(s)
    # made every one of these "invalid", and an earlier `:keep` dropped what it
    # warned about — so a deployment whose API is called by a browser extension
    # or a Capacitor/Tauri webview lost ALL of its CORS on the next boot, with
    # the only trace on stderr. An `Origin` is a serialized origin: any scheme.
    test "a non-http scheme is a real origin, not a mistake" do
      for good <- [
            "chrome-extension://abcdefghijklmnop",
            "moz-extension://a-b-c",
            "capacitor://localhost",
            "tauri://localhost",
            "app://obsidian.md",
            "http://[::1]:3000",
            "https://xn--nicode-2ya.com"
          ] do
        assert CORS.valid_origin?(good), good
      end
    end

    test "a browser-extension allowlist survives a boot untouched" do
      value = "chrome-extension://abcdefghijklmnop,https://acme.com"
      assert capture_io(:stderr, fn -> assert CORS.parse_env(value) end) == ""
      assert CORS.parse_env(value) == String.split(value, ",")
    end

    # A `*` inside a list cannot widen CORS the way it widens a CSP — the
    # comparison is equality, so it simply never matches. Worth asserting,
    # because it is the question #651 says nobody had asked here.
    test "a wildcard mixed into a list does not open the policy" do
      parsed = with_stderr_muted(fn -> CORS.parse_env("https://a.test,*") end)

      refute parsed == :all
      # `"*"` stays in the list, and is simply an entry no `Origin` equals.
      assert parsed == ["https://a.test", "*"]
    end

    # `capture_io/2` returns the captured output, not the block's value, so a
    # test that needs both runs the block for its value with stderr silenced.
    defp with_stderr_muted(fun) do
      parent = self()
      capture_io(:stderr, fn -> send(parent, {:result, fun.()}) end)
      receive do: ({:result, value} -> value)
    end

    test "valid_origin? accepts what a browser actually sends" do
      for good <- ["https://acme.com", "http://localhost:3000", "https://a.test:8443"] do
        assert CORS.valid_origin?(good), good
      end

      for bad <- [
            "https://acme.com/",
            "acme.com",
            "*",
            "null",
            "https://a.test/path",
            "",
            # No wildcard matching exists here, so this matches nothing at all —
            # and it is the likeliest mistake after a trailing slash.
            "https://*.acme.com",
            # Browsers downcase both, and the comparison is byte equality.
            "HTTP://ACME.COM",
            "https://Acme.com",
            # Browsers send punycode for an IDN.
            "https://ünicode.com",
            "https://acme.com;",
            "https://acme.com?a=1",
            "https://acme.com#x",
            # `file://` has no host; a browser sends `Origin: null` for it.
            "file://"
          ] do
        refute CORS.valid_origin?(bad), bad
      end
    end
  end

  # Embed keeps its own rejection policy, for its own reason.
  describe "EMBED_ORIGINS keeps discard-all" do
    test "a wildcard mixed into a list closes the policy entirely" do
      warning =
        capture_io(:stderr, fn ->
          assert Embed.parse_env("https://a.test,*") == []
        end)

      assert warning =~ "EMBED_ORIGINS"
    end

    test "a directive-injecting entry closes it too" do
      warning =
        capture_io(:stderr, fn ->
          assert Embed.parse_env("https://a.test; report-uri https://evil.test") == []
        end)

      assert warning =~ "EMBED_ORIGINS"
    end
  end
end
