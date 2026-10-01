defmodule KilnCMS.Config.PublicBaseUrlTest do
  @moduledoc """
  The pure half of `KilnCMS.Config.PublicBaseUrl` (#1833): normalization and
  the localhost boot warning. `test/config/runtime_env_flags_test.exs` covers
  `from_env/0` through a real production evaluation of `config/runtime.exs`.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Config.PublicBaseUrl

  doctest PublicBaseUrl

  describe "normalize!/2" do
    test "keeps an IPv6 host bracketed" do
      assert PublicBaseUrl.normalize!("http://[::1]:4000", "PUBLIC_BASE_URL") ==
               "http://[::1]:4000"
    end

    test "drops a rooted FQDN's trailing dot" do
      assert PublicBaseUrl.normalize!("https://cms.example.com./", "PUBLIC_BASE_URL") ==
               "https://cms.example.com"
    end

    test "names the variable the operator should fix" do
      assert_raise RuntimeError, ~r/^PHX_HOST does not give a usable/, fn ->
        PublicBaseUrl.normalize!("https://cms.example.com/path", "PHX_HOST")
      end
    end
  end

  describe "boot_warning/2" do
    test "warns on a production boot that links to this machine" do
      for url <- [
            "https://localhost",
            "http://localhost:4000",
            "http://127.0.0.1",
            "http://[::1]"
          ] do
        assert PublicBaseUrl.boot_warning(:prod, url) =~ "points at this machine"
      end
    end

    test "is silent for a real host, and outside :prod" do
      assert PublicBaseUrl.boot_warning(:prod, "https://cms.example.com") == nil
      assert PublicBaseUrl.boot_warning(:dev, "http://localhost:4000") == nil
      assert PublicBaseUrl.boot_warning(:test, "http://localhost:4000") == nil
    end

    test "is silent under test with the shipped config" do
      assert PublicBaseUrl.boot_warning() == nil
    end
  end
end
