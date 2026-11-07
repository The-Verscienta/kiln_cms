defmodule KilnCMSWeb.RobotsTest do
  @moduledoc """
  `KilnCMSWeb.Robots.directive/1` (#2256): the string behind both the meta tag
  and the `x-robots-tag` header, and its refusal to treat an unloaded flag as
  "no directive".
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.Robots

  test "builds the directive from the flags" do
    assert Robots.directive(%{noindex: true, nofollow: true}) == "noindex, nofollow"
    assert Robots.directive(%{noindex: true, nofollow: false}) == "noindex"
    assert Robots.directive(%{noindex: false, nofollow: true}) == "nofollow"
    assert Robots.directive(%{noindex: false, nofollow: false}) == nil
  end

  test "a map without the keys (a cache older than the flags) is no directive" do
    assert Robots.directive(%{}) == nil
  end

  test "an unloaded flag raises instead of reading as no directive" do
    not_loaded = %Ash.NotLoaded{field: :noindex, type: :attribute}

    assert_raise ArgumentError, ~r/noindex was not loaded/, fn ->
      Robots.directive(%{noindex: not_loaded, nofollow: false})
    end

    assert_raise ArgumentError, ~r/nofollow was not loaded/, fn ->
      Robots.directive(%{
        noindex: false,
        nofollow: %Ash.NotLoaded{field: :nofollow, type: :attribute}
      })
    end
  end
end
