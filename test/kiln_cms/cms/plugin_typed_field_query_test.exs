defmodule KilnCMS.CMS.PluginTypedFieldQueryTest do
  @moduledoc """
  `custom_filter`, `custom_where` and `custom_sort` on a plugin field type
  whose `graphql_kind/1` is `:int`, `:float`, `:boolean` or `:date` (#2855):
  the fixture plugin's `:score`, `:weight`, `:toggle` and `:deadline`.

  An operand that is a value of the field's kind compares as that value, so
  `9` is below `10` and `eq` matches a stored JSON number. Everything else is
  as it was, since the JSON:API filter semantics are a stable contract: an
  operand that is not of the kind is compared as the text sent (never a
  `400`), and `contains`, `starts_with` and `ilike` match the text.

  Field names are unique per test, so predicates on them only ever match
  records seeded here (shared-sandbox safety).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  @accept "application/vnd.api+json"

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ptq-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp field!(type, actor, content_type \\ :page) do
    name = "#{type}#{System.unique_integer([:positive])}"

    CMS.create_field_definition!(
      %{content_type: content_type, name: name, label: "F", field_type: type},
      actor: actor
    )

    name
  end

  defp page!(fields, actor) do
    CMS.create_page!(
      %{title: "P", slug: "ptq-#{System.unique_integer([:positive])}", custom_fields: fields},
      actor: actor
    )
  end

  defp ids!(inputs, actor),
    do: inputs |> CMS.list_pages!(actor: actor) |> Enum.map(& &1.id) |> Enum.sort()

  defp sorted(pages), do: pages |> Enum.map(& &1.id) |> Enum.sort()

  describe "an :int kind (:score)" do
    setup do
      admin = admin()
      name = field!(:score, admin)

      %{
        admin: admin,
        name: name,
        nine: page!(%{name => 9}, admin),
        ten: page!(%{name => "10"}, admin)
      }
    end

    test "stores a JSON number", %{admin: admin, name: name, ten: ten} do
      assert CMS.get_page!(ten.id, actor: admin).custom_fields[name] == 10
    end

    test "eq, in and the range operators compare numbers", ctx do
      %{admin: admin, name: name, nine: nine, ten: ten} = ctx
      f = &ids!(%{custom_filter: %{name => &1}}, admin)

      assert f.("10") == [ten.id]
      assert f.(%{"eq" => 9}) == [nine.id]
      assert f.(%{"not_eq" => "9"}) == [ten.id]
      assert f.(%{"in" => ["9", 10]}) == sorted([nine, ten])

      # As a jsonb string, "9" sat below every stored number: gt matched both.
      for operand <- ["9", 9], do: assert(f.(%{"gt" => operand}) == [ten.id])
      for operand <- ["10", 10], do: assert(f.(%{"lt" => operand}) == [nine.id])
      assert f.(%{"gte" => "9"}) == sorted([nine, ten])
    end

    test "custom_where's int condition compares numbers", ctx do
      %{admin: admin, name: name, nine: nine, ten: ten} = ctx
      w = &ids!(%{custom_where: [%{name: name, int: &1}]}, admin)

      assert w.(%{gt: 9}) == [ten.id]
      assert w.(%{lt: 10}) == [nine.id]
      assert w.(%{eq: 10}) == [ten.id]
      assert w.(%{in: [9]}) == [nine.id]
    end

    # Guard: as on main, an operand that is not a number is compared as the
    # text sent. A jsonb string sorts below every number, so `gt` finds both
    # and `lt` and `eq` neither. A 200 every time, never a 400.
    test "an operand that is not a number is compared as text, as before", ctx do
      %{admin: admin, name: name, nine: nine, ten: ten} = ctx
      f = &ids!(%{custom_filter: %{name => &1}}, admin)

      assert f.("ten") == []
      assert f.(%{"not_eq" => "ten"}) == sorted([nine, ten])
      assert f.(%{"gt" => "ten"}) == sorted([nine, ten])
      assert f.(%{"lt" => "ten"}) == []
      assert f.(%{"in" => ["ten", "nine"]}) == []
    end

    # Guard: the text operators keep matching the stored value's text.
    test "contains, starts_with and ilike still match as text", ctx do
      %{admin: admin, name: name, nine: nine, ten: ten} = ctx
      f = &ids!(%{custom_filter: %{name => &1}}, admin)

      assert f.(%{"contains" => "0"}) == [ten.id]
      assert f.(%{"starts_with" => "1"}) == [ten.id]
      assert f.(%{"starts_with" => "9"}) == [nine.id]
      assert f.(%{"ilike" => "%9%"}) == [nine.id]
    end

    # Guard: the sort compared the stored jsonb before #2855 too.
    test "custom_sort orders numbers", ctx do
      %{admin: admin, name: name, nine: nine, ten: ten} = ctx
      present = %{name => %{"null" => "false"}}

      read =
        &(CMS.list_pages!(%{custom_filter: present, custom_sort: &1}, actor: admin)
          |> Enum.map(fn p -> p.id end))

      assert read.(name) == [nine.id, ten.id]
      assert read.("-" <> name) == [ten.id, nine.id]
    end
  end

  test "a :float kind (:weight) compares numbers" do
    admin = admin()
    name = field!(:weight, admin)
    light = page!(%{name => 9.5}, admin)
    heavy = page!(%{name => "10.25"}, admin)
    f = &ids!(%{custom_filter: %{name => &1}}, admin)

    assert f.("9.5") == [light.id]
    assert f.(%{"in" => ["10.25"]}) == [heavy.id]
    assert f.(%{"gt" => "9.5"}) == [heavy.id]
    assert f.(%{"lt" => "10.25"}) == [light.id]
    assert ids!(%{custom_where: [%{name: name, float: %{gte: 10.0}}]}, admin) == [heavy.id]
  end

  test "a :boolean kind (:toggle) compares booleans" do
    admin = admin()
    name = field!(:toggle, admin)
    on = page!(%{name => true}, admin)
    off = page!(%{name => "false"}, admin)
    f = &ids!(%{custom_filter: %{name => &1}}, admin)

    assert f.("true") == [on.id]
    assert f.(%{"in" => ["false"]}) == [off.id]
    assert f.(%{"not_eq" => "true"}) == [off.id]
    assert f.(%{"gt" => "false"}) == [on.id]
    assert ids!(%{custom_where: [%{name: name, boolean: %{eq: false}}]}, admin) == [off.id]
  end

  # GraphQL hands `customWhere`'s date operands over as `%Date{}`s, which the
  # text comparison could not take (a 400); `custom_filter` already matched an
  # ISO date by its text and still does.
  test "a :date kind (:deadline) compares dates" do
    admin = admin()
    name = field!(:deadline, admin)
    nov = page!(%{name => "2026-11-05"}, admin)
    dec = page!(%{name => "2026-12-01"}, admin)
    w = &ids!(%{custom_where: [%{name: name, date: &1}]}, admin)

    assert w.(%{eq: ~D[2026-11-05]}) == [nov.id]
    assert w.(%{in: [~D[2026-12-01]]}) == [dec.id]
    assert w.(%{gt: ~D[2026-11-05]}) == [dec.id]
    assert w.(%{lte: ~D[2026-11-30]}) == [nov.id]

    f = &ids!(%{custom_filter: %{name => &1}}, admin)
    assert f.("2026-11-05") == [nov.id]
    assert f.(%{"gte" => "2026-11-06"}) == [dec.id]
    assert f.(%{"starts_with" => "2026-11"}) == [nov.id]
    # Not a date: compared as text, as before.
    assert f.("November") == []
  end

  # A value stored before the field was retyped stays where jsonb's order
  # puts it, exactly as on a core `:integer` field: never a crash, and the
  # numbers still compare as numbers among themselves.
  test "a stored value that is not a number neither crashes nor reorders the numbers" do
    admin = admin()

    [core, plugin] =
      for type <- [:integer, :score] do
        name = "retyped#{System.unique_integer([:positive])}"

        definition =
          CMS.create_field_definition!(
            %{content_type: :page, name: name, label: "F", field_type: :string},
            actor: admin
          )

        word = page!(%{name => "lots"}, admin)
        CMS.update_field_definition!(definition, %{field_type: type}, actor: admin)
        nine = page!(%{name => 9}, admin)
        ten = page!(%{name => 10}, admin)

        assert CMS.get_page!(word.id, actor: admin).custom_fields[name] == "lots"

        label = %{word.id => :word, nine.id => 9, ten.id => 10}

        read = fn inputs ->
          inputs |> CMS.list_pages!(actor: admin) |> Enum.map(&Map.fetch!(label, &1.id))
        end

        present = %{name => %{"null" => "false"}}
        gt = read.(%{custom_filter: %{name => %{"gt" => "9"}}})
        lt = read.(%{custom_filter: %{name => %{"lt" => 10}}})
        asc = read.(%{custom_filter: present, custom_sort: name})
        desc = read.(%{custom_filter: present, custom_sort: "-" <> name})

        assert 10 in gt and 9 not in gt
        assert 9 in lt and 10 not in lt
        assert read.(%{custom_filter: %{name => "10"}}) == [10]
        assert Enum.filter(asc, &is_integer/1) == [9, 10]
        assert Enum.filter(desc, &is_integer/1) == [10, 9]
        assert Enum.sort(asc) == Enum.sort([:word, 9, 10])

        {Enum.sort(gt), Enum.sort(lt), asc, desc}
      end

    assert plugin == core
  end

  test "JSON:API custom_filter on a plugin :int field compares numbers" do
    admin = admin()
    name = field!(:score, admin, :post)

    publish = fn score ->
      %{
        title: "Post #{score}",
        slug: "ptq-#{System.unique_integer([:positive])}",
        custom_fields: %{name => score}
      }
      |> CMS.create_post!(actor: admin)
      |> then(&CMS.publish_post!(&1, %{}, actor: admin))
    end

    nine = publish.(9)
    ten = publish.(10)

    get_ids = fn query ->
      conn =
        build_conn()
        |> put_req_header("accept", @accept)
        |> get("/api/json/posts?" <> query)

      assert conn.status == 200, conn.resp_body

      conn.resp_body
      |> Jason.decode!()
      |> Map.fetch!("data")
      |> Enum.map(& &1["id"])
      |> Enum.sort()
    end

    assert get_ids.("custom_filter[#{name}][gt]=9") == [ten.id]
    assert get_ids.("custom_filter[#{name}][lt]=10") == [nine.id]
    assert get_ids.("custom_filter[#{name}]=9") == [nine.id]
    # Not a number: compared as text, a 200 as before.
    assert get_ids.("custom_filter[#{name}][eq]=ten") == []
  end
end
