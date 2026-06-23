defmodule KilnCMS.Search.AnalyticsTest do
  @moduledoc """
  Phase E (#9): `KilnCMS.Search.record_query/3` upserts a privacy-first,
  normalized per-(query, locale) counter; `Analytics.top_searches` and
  `zero_result_searches` report on it. Reads are editor/admin only.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Analytics
  alias KilnCMS.Search

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "an-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp rows_for(query, actor) do
    Analytics.top_searches!(actor: actor) |> Enum.filter(&(&1.query == query))
  end

  test "records and increments a normalized counter" do
    admin = user(:admin)
    term = "elixir#{System.unique_integer([:positive])}"

    Search.record_query(String.upcase(term), 5)
    Search.record_query("  #{term}  ", 3)

    assert [row] = rows_for(term, admin)
    assert row.count == 2
    # Latest result count wins on upsert.
    assert row.result_count == 3
  end

  test "top_searches orders by frequency" do
    admin = user(:admin)
    a = "alpha#{System.unique_integer([:positive])}"
    b = "beta#{System.unique_integer([:positive])}"

    for _ <- 1..3, do: Search.record_query(a, 1)
    Search.record_query(b, 1)

    ranked = Analytics.top_searches!(actor: admin) |> Enum.map(& &1.query)
    assert Enum.find_index(ranked, &(&1 == a)) < Enum.find_index(ranked, &(&1 == b))
  end

  test "zero_result_searches surfaces only content-gap queries" do
    admin = user(:admin)
    found = "found#{System.unique_integer([:positive])}"
    gap = "gap#{System.unique_integer([:positive])}"

    Search.record_query(found, 7)
    Search.record_query(gap, 0)

    queries = Analytics.zero_result_searches!(actor: admin) |> Enum.map(& &1.query)
    assert gap in queries
    refute found in queries
  end

  test "reports are editor/admin only (viewers see nothing)" do
    term = "private#{System.unique_integer([:positive])}"
    Search.record_query(term, 1)

    assert Enum.any?(Analytics.top_searches!(actor: user(:editor)), &(&1.query == term))
    assert Analytics.top_searches!(actor: user(:viewer)) == []
  end
end
