defmodule KilnCMS.CMS.CustomSortKeysetTest do
  @moduledoc """
  Keyset paging over a `custom_sort` (#2293): the content list pages a custom
  field sort with the same `page: [after: keyset]` cursor as any other sort,
  so the jsonb sort key must survive being a cursor value — duplicates across
  a page boundary, rows without the key (SQL NULL), an explicit JSON `null`
  stored under it, off-type values, and string/boolean/float keys.

  Rows are seeded straight into `custom_fields` so values the write path would
  refuse (an off-type value, a stored `null`) are present too. Every row of a
  test carries one unique title, which is how the reads are scoped.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cks-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp field_name(base), do: "#{base}#{System.unique_integer([:positive])}"

  defp define!(name, type, admin) do
    CMS.create_field_definition!(
      %{content_type: :page, label: "Field", name: name, field_type: type},
      actor: admin
    )
  end

  defp seed!(title, fields) do
    Ash.Seed.seed!(KilnCMS.CMS.Page, %{
      title: title,
      slug: "cks-#{System.unique_integer([:positive])}",
      locale: "en",
      custom_fields: fields
    })
  end

  # Every page read in `title`'s scope, sorted by `sort`, one keyset page at a
  # time of `limit` rows; the ids in the order the walk returned them.
  defp walk(title, sort, admin, limit) do
    Stream.unfold(nil, fn
      :done ->
        nil

      cursor ->
        page_opts = [limit: limit] ++ if(cursor, do: [after: cursor], else: [])

        page =
          CMS.list_pages!(%{custom_sort: sort},
            actor: admin,
            page: page_opts,
            query: [filter: [title: title]]
          )

        case page.results do
          [] ->
            nil

          results ->
            {Enum.map(results, & &1.id),
             if(page.more?, do: List.last(results).__metadata__.keyset, else: :done)}
        end
    end)
    |> Enum.to_list()
    |> List.flatten()
  end

  # The reference order: one walk at the largest page size the read allows.
  # (A page is capped at 100 rows, so 130 rows still cross one boundary here;
  # each test also asserts the values come out ordered.)
  defp assert_walks_alike(title, sort, admin, expected_count) do
    reference = walk(title, sort, admin, 100)
    assert length(reference) == expected_count
    assert reference == Enum.uniq(reference)

    for limit <- [1, 3, 7, 50] do
      walked = walk(title, sort, admin, limit)
      assert length(walked) == expected_count, "limit #{limit}: skipped or repeated rows"
      assert walked == reference, "limit #{limit}: order differs from the reference walk"
    end

    reference
  end

  setup do
    {:ok, admin: admin(), title: "cks #{System.unique_integer([:positive])}"}
  end

  test "integer key: 130 rows over 5 distinct values, plus missing keys", ctx do
    %{admin: admin, title: title} = ctx
    price = field_name("price")
    define!(price, :integer, admin)

    for i <- 1..120, do: seed!(title, %{price => rem(i, 5)})
    for _ <- 1..10, do: seed!(title, %{})

    for sort <- [price, "-#{price}"] do
      ids = assert_walks_alike(title, sort, admin, 130)
      rows = Map.new(CMS.list_pages!(actor: admin, query: [filter: [title: title]]), &{&1.id, &1})
      values = Enum.map(ids, &get_in(rows[&1].custom_fields, [price]))

      # Missing keys come last in both directions.
      assert Enum.take(values, -10) == List.duplicate(nil, 10)
      present = Enum.take(values, 120)
      assert present == if(sort == price, do: Enum.sort(present), else: Enum.sort(present, :desc))
    end
  end

  test "an explicit JSON null stored under the key pages like a missing key", ctx do
    %{admin: admin, title: title} = ctx
    price = field_name("price")
    define!(price, :integer, admin)

    for i <- 1..30, do: seed!(title, %{price => rem(i, 3)})
    for _ <- 1..12, do: seed!(title, %{price => nil})
    for _ <- 1..12, do: seed!(title, %{})

    for sort <- [price, "-#{price}"] do
      ids = assert_walks_alike(title, sort, admin, 54)
      rows = Map.new(CMS.list_pages!(actor: admin, query: [filter: [title: title]]), &{&1.id, &1})
      values = Enum.map(ids, &rows[&1].custom_fields[price])

      # Both flavours of "no value" sit after every real value.
      assert Enum.take(values, 30) |> Enum.all?(&is_integer/1)
      assert Enum.take(values, -24) |> Enum.all?(&is_nil/1)
    end
  end

  test "a string key whose values look numeric pages by text order", ctx do
    %{admin: admin, title: title} = ctx
    code = field_name("code")
    define!(code, :string, admin)

    values = ~w(10 9 100 9 10 007 7 9)
    for i <- 1..40, do: seed!(title, %{code => Enum.at(values, rem(i, length(values)))})
    for _ <- 1..4, do: seed!(title, %{})

    ids = assert_walks_alike(title, code, admin, 44)
    rows = Map.new(CMS.list_pages!(actor: admin, query: [filter: [title: title]]), &{&1.id, &1})
    present = ids |> Enum.map(&rows[&1].custom_fields[code]) |> Enum.take(40)
    assert present == Enum.sort(present)
  end

  test "a boolean key pages with ties on both values", ctx do
    %{admin: admin, title: title} = ctx
    flag = field_name("flag")
    define!(flag, :boolean, admin)

    for i <- 1..40, do: seed!(title, %{flag => rem(i, 3) == 0})
    for _ <- 1..3, do: seed!(title, %{})

    assert_walks_alike(title, flag, admin, 43)
    assert_walks_alike(title, "-#{flag}", admin, 43)
  end

  test "a float key pages, including values that print without a fraction", ctx do
    %{admin: admin, title: title} = ctx
    score = field_name("score")
    define!(score, :float, admin)

    values = [1.5, 2.0, 2.25, 0.1, 1.5, 10.75]
    for i <- 1..40, do: seed!(title, %{score => Enum.at(values, rem(i, length(values)))})
    for _ <- 1..3, do: seed!(title, %{})

    assert_walks_alike(title, score, admin, 43)
    assert_walks_alike(title, "-#{score}", admin, 43)
  end

  test "off-type values mixed into the key still page without skips or repeats", ctx do
    %{admin: admin, title: title} = ctx
    price = field_name("price")
    define!(price, :integer, admin)

    mixed = [1, 2, 2, "abc", true, 3.5, "10", [1, 2], %{"a" => 1}]
    for i <- 1..60, do: seed!(title, %{price => Enum.at(mixed, rem(i, length(mixed)))})
    for _ <- 1..5, do: seed!(title, %{})

    assert_walks_alike(title, price, admin, 65)
    assert_walks_alike(title, "-#{price}", admin, 65)
  end
end
