defmodule KilnCMS.CMS.ScalarListQueryTest do
  @moduledoc """
  `custom_filter` / `custom_sort` on a `multiple` scalar field (#2289,
  `Preparations.CustomFieldQuery.Lists`): membership (`eq`, `not_eq`, `in`,
  `has`, `has_all`, `has_none`), `count`, `null`; the deferred operators and
  the sort refused; a stale bare value read as a one-item list; and owners
  that disagree on `multiple` refused on an unscoped entry query.

  Field names are unique per test, so a predicate only ever matches records
  seeded here — except where no-value rows match (`has_none`, `count` 0),
  which is asserted by membership.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Repo

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "slq-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp list!(type, admin, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :page,
          name: "l#{System.unique_integer([:positive])}",
          label: "List",
          field_type: type,
          multiple: true
        },
        attrs
      ),
      actor: admin
    )
  end

  defp slug, do: "slq-#{System.unique_integer([:positive])}"

  defp page!(fields, actor),
    do: CMS.create_page!(%{title: "P", slug: slug(), custom_fields: fields}, actor: actor)

  defp ids!(filter, admin) do
    %{custom_filter: filter} |> CMS.list_pages!(actor: admin) |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp error!(inputs, admin) do
    assert {:error, %Ash.Error.Invalid{} = error} = CMS.list_pages(inputs, actor: admin)
    Exception.message(error)
  end

  defp sorted(pages), do: pages |> Enum.map(& &1.id) |> Enum.sort()

  # A value written before the field was a list: a bare scalar under its key.
  defp store_raw!(page, name, json) do
    Repo.query!(
      "UPDATE pages SET custom_fields = jsonb_set(custom_fields, ARRAY[$2::text], $3::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(page.id), name, json]
    )
  end

  describe "membership" do
    test "integer eq casts the operand, so \"10\" finds the number 10" do
      admin = admin()
      scores = list!(:integer, admin)

      ten = page!(%{scores.name => [3, 10]}, admin)
      _other = page!(%{scores.name => [1]}, admin)

      assert ids!(%{scores.name => "10"}, admin) == [ten.id]
      assert ids!(%{scores.name => %{"eq" => 10}}, admin) == [ten.id]
      assert error!(%{custom_filter: %{scores.name => "ten"}}, admin) =~ "invalid integer value"
    end

    test "a float list matches by value: 10 finds a stored 10.0" do
      admin = admin()
      weights = list!(:float, admin)

      ten = page!(%{weights.name => [10.0, 2.5]}, admin)
      _other = page!(%{weights.name => [2.5]}, admin)

      assert ids!(%{weights.name => 10}, admin) == [ten.id]
      assert ids!(%{weights.name => "10"}, admin) == [ten.id]
    end

    test "date eq and in" do
      admin = admin()
      dates = list!(:date, admin)

      march = page!(%{dates.name => ["2026-03-01", "2026-05-01"]}, admin)
      june = page!(%{dates.name => ["2026-06-01"]}, admin)
      _july = page!(%{dates.name => ["2026-07-01"]}, admin)

      assert ids!(%{dates.name => "2026-03-01"}, admin) == [march.id]

      assert ids!(%{dates.name => %{"in" => ["2026-05-01", "2026-06-01"]}}, admin) ==
               sorted([march, june])

      assert ids!(%{dates.name => %{"in" => []}}, admin) == []
      assert error!(%{custom_filter: %{dates.name => "March"}}, admin) =~ "invalid date value"
    end

    test "an operand is coerced as the item was stored (colour, email, time, date-time)" do
      admin = admin()
      colours = list!(:color, admin)
      emails = list!(:email, admin)
      times = list!(:time, admin)
      stamps = list!(:datetime, admin)

      page =
        page!(
          %{
            colours.name => ["#FFF"],
            emails.name => ["a@Example.com"],
            times.name => ["9:30"],
            stamps.name => ["2026-03-01T10:00:00.250"]
          },
          admin
        )

      _other =
        page!(
          %{
            colours.name => ["#000"],
            emails.name => ["b@example.com"],
            times.name => ["10:30"],
            stamps.name => ["2026-03-01T11:00:00"]
          },
          admin
        )

      assert ids!(%{colours.name => "#FFF"}, admin) == [page.id]
      assert ids!(%{colours.name => %{"has" => ["#ffffff"]}}, admin) == [page.id]
      assert ids!(%{emails.name => "a@Example.com"}, admin) == [page.id]
      assert ids!(%{times.name => "9:30"}, admin) == [page.id]
      assert ids!(%{stamps.name => "2026-03-01T10:00:00.250"}, admin) == [page.id]
    end

    test "not_eq is does-not-contain, and leaves out a record with no value" do
      admin = admin()
      scores = list!(:integer, admin)

      with_3 = page!(%{scores.name => [3, 4]}, admin)
      without_3 = page!(%{scores.name => [4]}, admin)
      none = page!(%{}, admin)

      matches = ids!(%{scores.name => %{"not_eq" => "3"}}, admin)

      assert without_3.id in matches
      refute with_3.id in matches
      refute none.id in matches
    end

    test "has, has_all and has_none; has_none includes a record with no value" do
      admin = admin()
      dates = list!(:date, admin)

      both = page!(%{dates.name => ["2026-01-01", "2026-02-01"]}, admin)
      jan = page!(%{dates.name => ["2026-01-01"]}, admin)
      feb = page!(%{dates.name => ["2026-02-01", "2026-03-01"]}, admin)
      none = page!(%{}, admin)

      assert ids!(%{dates.name => %{"has" => "2026-01-01"}}, admin) == sorted([both, jan])

      assert ids!(%{dates.name => %{"has" => ["2026-01-01", "2026-03-01"]}}, admin) ==
               sorted([both, jan, feb])

      assert ids!(%{dates.name => %{"has_all" => ["2026-01-01", "2026-02-01"]}}, admin) ==
               [both.id]

      without_jan = ids!(%{dates.name => %{"has_none" => ["2026-01-01"]}}, admin)
      assert feb.id in without_jan
      assert none.id in without_jan
      refute both.id in without_jan
      refute jan.id in without_jan
    end

    test "has takes at most Relations.max_ids/0 values and at least one" do
      admin = admin()
      scores = list!(:integer, admin)
      too_many = Enum.to_list(1..101)

      assert error!(%{custom_filter: %{scores.name => %{"has" => too_many}}}, admin) =~
               "has for #{inspect(scores.name)} takes at most 100 values"

      message = error!(%{custom_filter: %{scores.name => %{"has_all" => []}}}, admin)
      assert message =~ "needs at least one value"
      refute message =~ ~r/\bids?\b/

      assert error!(%{custom_filter: %{scores.name => %{"has_none" => ["x"]}}}, admin) =~
               "invalid integer value"
    end

    test "string and select lists take has, has_none and count too" do
      admin = admin()
      phrases = list!(:string, admin)

      terms = list!(:select, admin, %{options: ["a", "b"]})

      one = page!(%{phrases.name => ["red", "blue"], terms.name => ["a"]}, admin)
      two = page!(%{phrases.name => ["green"], terms.name => ["a", "b"]}, admin)

      assert ids!(%{phrases.name => %{"has" => ["blue", "green"]}}, admin) == sorted([one, two])
      assert ids!(%{phrases.name => %{"count" => 2}}, admin) == [one.id]
      assert ids!(%{terms.name => %{"has_all" => ["a", "b"]}}, admin) == [two.id]

      refute one.id in ids!(%{terms.name => %{"has_none" => "a"}}, admin)
    end

    test "a number operand on a list of phrases is read as text" do
      admin = admin()
      phrases = list!(:string, admin)

      ten = page!(%{phrases.name => ["10", "x"]}, admin)

      assert ids!(%{phrases.name => 10}, admin) == [ten.id]
      assert ids!(%{phrases.name => %{"has" => [10]}}, admin) == [ten.id]
    end
  end

  describe "count" do
    test "eq and comparisons; count 0 is a record with no value" do
      admin = admin()
      scores = list!(:integer, admin)

      one = page!(%{scores.name => [5]}, admin)
      three = page!(%{scores.name => [5, 5, 6]}, admin)
      none = page!(%{}, admin)

      assert ids!(%{scores.name => %{"count" => "3"}}, admin) == [three.id]
      assert ids!(%{scores.name => %{"count" => %{"gte" => 1}}}, admin) == sorted([one, three])
      assert ids!(%{scores.name => %{"count" => %{"gt" => 0, "lt" => 3}}}, admin) == [one.id]

      zero = ids!(%{scores.name => %{"count" => %{"eq" => 0}}}, admin)
      assert none.id in zero
      refute one.id in zero

      assert error!(%{custom_filter: %{scores.name => %{"count" => "-1"}}}, admin) =~
               "whole number"
    end
  end

  describe "what a list does not take" do
    test "per-item comparisons, text matching and ilike name the supported operators" do
      admin = admin()
      scores = list!(:integer, admin)
      links = list!(:url, admin)

      for {field, op, value} <- [
            {scores, "gt", "3"},
            {scores, "lte", "3"},
            {links, "contains", "example"},
            {links, "starts_with", "https"},
            {links, "ilike", "%example%"},
            {links, "gt", "a"}
          ] do
        message = error!(%{custom_filter: %{field.name => %{op => value}}}, admin)

        assert message =~ "#{op} is not supported on custom field #{inspect(field.name)} (a list)"
        assert message =~ "eq/not_eq/in/has/has_all/has_none/count/null"
      end
    end

    test "has and count on a single scalar are still relationship operators" do
      admin = admin()

      single = "s#{System.unique_integer([:positive])}"

      CMS.create_field_definition!(
        %{content_type: :page, name: single, label: "S", field_type: :integer},
        actor: admin
      )

      for op <- ~w(has count) do
        message = error!(%{custom_filter: %{single => %{op => "1"}}}, admin)
        assert message =~ "#{op} is a relationship operator"
      end
    end

    test "a list is not sortable" do
      admin = admin()

      for type <- [:integer, :date, :url, :string] do
        field = list!(type, admin)

        assert error!(%{custom_sort: field.name}, admin) =~
                 "custom field #{inspect(field.name)} (a list) is not sortable"
      end
    end

    test "null works as on any field" do
      admin = admin()
      scores = list!(:integer, admin)

      set = page!(%{scores.name => [1]}, admin)
      unset = page!(%{}, admin)

      without = ids!(%{scores.name => %{"is_nil" => true}}, admin)
      assert unset.id in without
      refute set.id in without
      assert ids!(%{scores.name => %{"null" => false}}, admin) == [set.id]
    end
  end

  describe "a bare value stored before the field was a list" do
    test "is read as a one-item list by every operator, never failing" do
      admin = admin()
      dates = list!(:date, admin)
      scores = list!(:integer, admin)

      stale = page!(%{}, admin)
      store_raw!(stale, dates.name, ~s("2026-03-01"))
      store_raw!(stale, scores.name, "7")
      listed = page!(%{dates.name => ["2026-04-01"], scores.name => [8, 9]}, admin)

      assert ids!(%{dates.name => "2026-03-01"}, admin) == [stale.id]
      assert ids!(%{scores.name => "7"}, admin) == [stale.id]
      assert ids!(%{scores.name => %{"in" => [7, 8]}}, admin) == sorted([stale, listed])
      assert ids!(%{dates.name => %{"has" => ["2026-03-01"]}}, admin) == [stale.id]
      assert ids!(%{scores.name => %{"has_all" => [7]}}, admin) == [stale.id]
      assert ids!(%{scores.name => %{"has_all" => [7, 8]}}, admin) == []
      assert ids!(%{scores.name => %{"count" => 1}}, admin) == [stale.id]

      assert ids!(%{scores.name => %{"not_eq" => 8}}, admin) == [stale.id]
      assert ids!(%{scores.name => %{"not_eq" => 7}}, admin) == [listed.id]

      none_7 = ids!(%{scores.name => %{"has_none" => [7]}}, admin)
      assert listed.id in none_7
      refute stale.id in none_7

      assert ids!(%{dates.name => %{"null" => false}}, admin) == sorted([stale, listed])
    end
  end

  describe "owners that disagree on multiple" do
    defp type!(admin) do
      CMS.create_type_definition!(
        %{name: "slqdyn#{System.unique_integer([:positive])}", label: "Dyn"},
        actor: admin
      )
    end

    test "an unscoped entry query is refused; a scoped one reads its own owner" do
      admin = admin()
      name = "when#{System.unique_integer([:positive])}"
      events = type!(admin)
      notes = type!(admin)

      CMS.create_field_definition!(
        %{type_definition_id: events.id, name: name, label: "When", field_type: :date},
        actor: admin
      )

      CMS.create_field_definition!(
        %{
          type_definition_id: notes.id,
          name: name,
          label: "When",
          field_type: :date,
          multiple: true
        },
        actor: admin
      )

      note =
        KilnCMS.CMS.ContentTypes.create!(
          notes.name,
          %{title: "N", slug: slug(), custom_fields: %{name => ["2026-03-01"]}},
          actor: admin
        )

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.list_entries(%{custom_filter: %{name => "2026-03-01"}}, actor: admin)

      assert Exception.message(error) =~ "different type per content type"

      scoped =
        CMS.list_entries!(
          %{custom_filter: %{name => %{"has" => "2026-03-01"}}},
          query: [filter: [type_name: notes.name]],
          actor: admin
        )

      assert Enum.map(scoped, & &1.id) == [note.id]
    end
  end
end
