defmodule KilnCMSWeb.SafeRedirectTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias KilnCMSWeb.SafeRedirect

  describe "safe_local_path?/1" do
    test "accepts absolute same-origin local paths" do
      assert SafeRedirect.safe_local_path?("/editor/foo")
      assert SafeRedirect.safe_local_path?("/")
      assert SafeRedirect.safe_local_path?("/a/b?c=1#d")
    end

    test "rejects off-site and malformed targets" do
      refute SafeRedirect.safe_local_path?("//evil.com")
      refute SafeRedirect.safe_local_path?("/\\evil.com")
      refute SafeRedirect.safe_local_path?("https://evil.com")
      refute SafeRedirect.safe_local_path?("http://evil.com")
      refute SafeRedirect.safe_local_path?("javascript:alert(1)")
      refute SafeRedirect.safe_local_path?("editor/foo")
      refute SafeRedirect.safe_local_path?(nil)
      refute SafeRedirect.safe_local_path?("")
    end
  end

  describe "local_path/2" do
    test "returns the path when safe" do
      assert SafeRedirect.local_path("/editor", "/") == "/editor"
    end

    test "falls back when unsafe or non-binary" do
      assert SafeRedirect.local_path("//evil.com", "/home") == "/home"
      assert SafeRedirect.local_path("https://evil.com", "/home") == "/home"
      assert SafeRedirect.local_path(nil, "/home") == "/home"
    end
  end
end
