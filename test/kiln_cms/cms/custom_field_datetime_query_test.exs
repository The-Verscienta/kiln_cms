defmodule KilnCMS.CMS.CustomFieldDatetimeQueryTest do
  @moduledoc """
  Filtering a `datetime` custom field (#2678). A write stores the wall-clock
  time as sent, offset dropped, with the fractional-second digits the client
  sent, so one time can be stored as `10:00:00.25`, `10:00:00.250` or
  `10:00:00.250000`. A filter reads its operand the same way and matches every
  such spelling, on a single field, a reference's link field and a list.

  Field names are unique per test, so predicates only ever match records
  seeded here.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Preparations.CustomFieldQuery.DateTimes

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cfdt-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp field_name(base), do: "#{base}#{System.unique_integer([:positive])}"

  defp slug, do: "cfdt-#{System.unique_integer([:positive])}"

  defp define!(attrs, actor) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :post, label: "Field"}, attrs),
      actor: actor
    )
  end

  defp post!(fields, actor) do
    %{title: "P", slug: slug(), custom_fields: fields}
    |> CMS.create_post!(actor: actor)
    |> then(&CMS.publish_post!(&1, %{}, actor: actor))
  end

  defp ids!(filter, actor, scope) do
    in_scope = MapSet.new(scope, & &1.id)

    %{custom_filter: filter}
    |> CMS.list_posts!(actor: actor)
    |> Enum.map(& &1.id)
    |> Enum.filter(&MapSet.member?(in_scope, &1))
    |> Enum.sort()
  end

  defp sorted(posts), do: posts |> Enum.map(& &1.id) |> Enum.sort()

  describe "DateTimes" do
    test "spellings are every text a write could store for the time" do
      assert DateTimes.spellings(~N[2026-01-01 10:00:00.25]) == [
               "2026-01-01T10:00:00.25",
               "2026-01-01T10:00:00.250",
               "2026-01-01T10:00:00.2500",
               "2026-01-01T10:00:00.25000",
               "2026-01-01T10:00:00.250000"
             ]

      assert DateTimes.spellings(~N[2026-01-01 10:00:00]) |> length() == 7
      assert DateTimes.spellings(~N[2026-01-01 10:00:00]) |> hd() == "2026-01-01T10:00:00"
      assert DateTimes.spellings(~N[2026-01-01 10:00:00.000]) |> hd() == "2026-01-01T10:00:00"

      assert DateTimes.spellings(~N[2026-01-01 10:00:00.000001]) == [
               "2026-01-01T10:00:00.000001"
             ]
    end

    test "a range bound is the longest spelling for gt and lte, the shortest for gte and lt" do
      time = ~N[2026-01-01 10:00:00.5]

      assert DateTimes.bound("gt", time) == "2026-01-01T10:00:00.500000"
      assert DateTimes.bound("lte", time) == "2026-01-01T10:00:00.500000"
      assert DateTimes.bound("gte", time) == "2026-01-01T10:00:00.5"
      assert DateTimes.bound("lt", time) == "2026-01-01T10:00:00.5"
    end

    test "cast drops the offset as a write does and keeps the fraction" do
      assert DateTimes.cast("2026-01-01T12:00:00.25+02:00") == {:ok, ~N[2026-01-01 12:00:00.25]}
      assert DateTimes.cast("2026-01-01T12:00:00Z") == {:ok, ~N[2026-01-01 12:00:00]}
      # The HTML datetime-local shape a write takes.
      assert DateTimes.cast("2026-01-01T12:00") == {:ok, ~N[2026-01-01 12:00:00]}
      assert DateTimes.cast("noon") == :error
      assert DateTimes.cast(%{"year" => 2026}) == :error
    end
  end

  describe "a single field" do
    setup do
      admin = admin()
      at = field_name("at")
      define!(%{name: at, field_type: :datetime}, admin)

      # One time spelled three ways, then the times on either side of it.
      short = post!(%{at => "2026-01-01T10:00:00.25"}, admin)
      padded = post!(%{at => "2026-01-01T10:00:00.250"}, admin)
      full = post!(%{at => "2026-01-01T10:00:00.250000"}, admin)
      whole = post!(%{at => "2026-01-01T10:00:00"}, admin)
      later = post!(%{at => "2026-01-01T10:00:00.5"}, admin)

      %{
        admin: admin,
        at: at,
        same: [short, padded, full],
        whole: whole,
        later: later,
        scope: [short, padded, full, whole, later]
      }
    end

    test "eq, not_eq and in match every stored spelling of the time", ctx do
      m = &ids!(%{ctx.at => &1}, ctx.admin, ctx.scope)

      for operand <- [
            "2026-01-01T10:00:00.25",
            "2026-01-01T10:00:00.2500",
            "2026-01-01 10:00:00.250000"
          ] do
        assert m.(operand) == sorted(ctx.same)
      end

      assert m.(%{"eq" => "2026-01-01T10:00:00"}) == [ctx.whole.id]
      assert m.(%{"eq" => "2026-01-01T10:00:00.000"}) == [ctx.whole.id]
      assert m.(%{"not_eq" => "2026-01-01T10:00:00.25"}) == sorted([ctx.whole, ctx.later])

      assert m.(%{"in" => ["2026-01-01T10:00:00.250", "2026-01-01T10:00:00.50"]}) ==
               sorted([ctx.later | ctx.same])
    end

    test "range operators hold at sub-second boundaries, whatever the stored spelling", ctx do
      m = &ids!(%{ctx.at => &1}, ctx.admin, ctx.scope)
      t = "2026-01-01T10:00:00.25"

      assert m.(%{"gt" => t}) == [ctx.later.id]
      assert m.(%{"gte" => t}) == sorted([ctx.later | ctx.same])
      assert m.(%{"lt" => t}) == [ctx.whole.id]
      assert m.(%{"lte" => t}) == sorted([ctx.whole | ctx.same])

      # A whole-second operand against fractional stored values.
      assert m.(%{"gt" => "2026-01-01T10:00:00"}) == sorted([ctx.later | ctx.same])
      assert m.(%{"lte" => "2026-01-01T10:00:00"}) == [ctx.whole.id]

      assert m.(%{"gte" => "2026-01-01T10:00:00.2", "lt" => "2026-01-01T10:00:00.3"}) ==
               sorted(ctx.same)
    end

    test "an offset is dropped, as the write dropped it: the time is compared as written",
         ctx do
      m = &ids!(%{ctx.at => &1}, ctx.admin, ctx.scope)

      assert m.("2026-01-01T10:00:00.25+02:00") == sorted(ctx.same)
      assert m.("2026-01-01T10:00:00.25Z") == sorted(ctx.same)
      assert m.("2026-01-01T08:00:00.25Z") == []
      assert m.(%{"gte" => "2026-01-01T10:00:00.5-05:00"}) == [ctx.later.id]
    end

    test "an operand that is not a date-time is a 400", ctx do
      assert {:error, error} = CMS.list_posts(%{custom_filter: %{ctx.at => "noon"}})
      assert Exception.message(error) =~ "invalid naive_datetime value"
    end
  end

  describe "a reference's link field" do
    setup do
      admin = admin()

      field =
        define!(
          %{
            name: field_name("stops"),
            field_type: :reference,
            target_type: "page",
            multiple: true
          },
          admin
        )

      CMS.create_field_definition!(
        %{name: "arrives", label: "Arrives", field_type: :datetime, link_of_id: field.id},
        actor: admin
      )

      page =
        %{title: "Stop", slug: slug()}
        |> CMS.create_page!(actor: admin)
        |> then(&CMS.publish_page!(&1, %{}, actor: admin))

      stop = fn at ->
        post!(%{field.name => [%{"id" => page.id, "link" => %{"arrives" => at}}]}, admin)
      end

      short = stop.("2026-01-01T10:00:00.25")
      full = stop.("2026-01-01T10:00:00.250000")
      whole = stop.("2026-01-01T10:00:00")

      %{admin: admin, key: "#{field.name}.link.arrives", short: short, full: full, whole: whole}
    end

    test "eq, in and the range operators read every stored spelling", ctx do
      scope = [ctx.short, ctx.full, ctx.whole]
      m = &ids!(%{ctx.key => &1}, ctx.admin, scope)

      assert m.("2026-01-01T10:00:00.250") == sorted([ctx.short, ctx.full])
      assert m.(%{"in" => ["2026-01-01T10:00:00.2500"]}) == sorted([ctx.short, ctx.full])
      assert m.(%{"not_eq" => "2026-01-01T10:00:00.25"}) == [ctx.whole.id]
      assert m.(%{"lte" => "2026-01-01T10:00:00.25"}) == sorted(scope)
      assert m.(%{"lt" => "2026-01-01T10:00:00.25"}) == [ctx.whole.id]
      assert m.(%{"gt" => "2026-01-01T10:00:00"}) == sorted([ctx.short, ctx.full])
    end
  end

  describe "a list of date-times" do
    setup do
      admin = admin()
      at = field_name("times")
      define!(%{name: at, field_type: :datetime, multiple: true}, admin)

      one = post!(%{at => ["2026-01-01T10:00:00.25", "2026-02-01T09:00:00"]}, admin)
      two = post!(%{at => ["2026-01-01T10:00:00.250000"]}, admin)
      three = post!(%{at => ["2026-03-01T09:00:00.5"]}, admin)

      %{admin: admin, at: at, one: one, two: two, three: three, scope: [one, two, three]}
    end

    test "membership matches every stored spelling of an item", ctx do
      m = &ids!(%{ctx.at => &1}, ctx.admin, ctx.scope)

      assert m.("2026-01-01T10:00:00.250") == sorted([ctx.one, ctx.two])
      assert m.(%{"not_eq" => "2026-01-01T10:00:00.25"}) == [ctx.three.id]

      assert m.(%{"in" => ["2026-01-01T10:00:00.25", "2026-03-01T09:00:00.500"]}) ==
               sorted([ctx.one, ctx.two, ctx.three])

      assert m.(%{"has" => ["2026-03-01T09:00:00.50"]}) == [ctx.three.id]

      assert m.(%{"has_all" => ["2026-01-01T10:00:00.2500", "2026-02-01T09:00:00.000"]}) ==
               [ctx.one.id]

      assert m.(%{"has_none" => ["2026-01-01T10:00:00.25"]}) == [ctx.three.id]
    end
  end

  describe "the in cap" do
    test "in takes at most 1000 values in all, across fields and groups" do
      admin = admin()
      at = field_name("at")
      define!(%{name: at, field_type: :datetime}, admin)

      values = for second <- 0..499, do: "2026-01-01T10:00:00.#{second}"

      # 500 + 500 is within the cap.
      assert {:ok, _} =
               CMS.list_posts(
                 %{
                   custom_filter: %{
                     "_or" => [%{at => %{"in" => values}}, %{at => %{"in" => values}}]
                   }
                 },
                 actor: admin
               )

      assert {:error, error} =
               CMS.list_posts(
                 %{
                   custom_filter: %{
                     at => %{"in" => values},
                     "_or" => [%{at => %{"in" => values}}, %{at => %{"in" => ["x"]}}]
                   }
                 },
                 actor: admin
               )

      assert Exception.message(error) =~
               "in takes at most 1000 values in all, across every condition and group (got 1001)"
    end
  end
end
