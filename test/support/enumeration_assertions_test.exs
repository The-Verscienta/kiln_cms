defmodule KilnCMS.EnumerationAssertionsTest do
  @moduledoc """
  The comparison tool itself: it must fail on a difference as small as one word
  of a body, and must not fail on the address a form echoes back.
  """
  use ExUnit.Case, async: true

  import KilnCMS.EnumerationAssertions

  defp resp(status, body, flash \\ %{}) do
    conn = Plug.Test.conn(:get, "/") |> Plug.Conn.resp(status, body)
    %{conn | private: Map.put(conn.private, :phoenix_flash, flash)}
  end

  test "equal responses pass, and an echoed address is scrubbed" do
    assert %{status: 401, body: ~s({"for":"<EMAIL>"})} =
             assert_indistinguishable(
               fn -> resp(401, ~s({"for":"a@example.com"})) end,
               fn -> resp(401, ~s({"for":"b@example.com"})) end,
               ["a@example.com", "b@example.com"]
             )
  end

  test "a one-word difference in the body fails" do
    assert_raise ExUnit.AssertionError, fn ->
      assert_indistinguishable(
        fn -> resp(401, "Invalid email or password") end,
        fn -> resp(401, "Invalid email or password.") end,
        []
      )
    end
  end

  test "a different status fails" do
    assert_raise ExUnit.AssertionError, fn ->
      assert_indistinguishable(fn -> resp(401, "x") end, fn -> resp(404, "x") end, [])
    end
  end

  test "a different flash fails" do
    assert_raise ExUnit.AssertionError, fn ->
      assert_indistinguishable(
        fn -> resp(302, "", %{"error" => "a"}) end,
        fn -> resp(302, "", %{"error" => "b"}) end,
        []
      )
    end
  end

  test "count_calls tallies the calls made while the function runs" do
    {:done, counts} =
      count_calls(fn -> Enum.each(1..3, fn _ -> String.upcase("a") end) && :done end, [
        {String, :upcase, 1},
        {String, :downcase, 1}
      ])

    assert counts == %{{String, :upcase, 1} => 3, {String, :downcase, 1} => 0}
  end
end
