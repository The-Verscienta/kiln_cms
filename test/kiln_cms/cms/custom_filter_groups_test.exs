defmodule KilnCMS.CMS.CustomFilterGroupsTest do
  @moduledoc """
  Boolean groups over custom fields (#2355) — `custom_filter[_or]` / `[_and]` /
  `[_not]` with `_native` for built-in columns — the mixed order that puts a
  custom sort before a built-in one (`_native:` in `custom_sort`, #2356), and the
  refusal of a reference / media sort (#2354).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cfg-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define!(attrs, actor) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, label: "Field"}, attrs),
      actor: actor
    )
  end

  defp name(base), do: "#{base}#{System.unique_integer([:positive])}"

  defp page!(title, fields, actor) do
    CMS.create_page!(
      %{title: title, slug: "cfg-#{System.unique_integer([:positive])}", custom_fields: fields},
      actor: actor
    )
  end

  defp ids(inputs, actor), do: inputs |> CMS.list_pages!(actor: actor) |> Enum.map(& &1.id)

  defp sorted_ids(inputs, actor), do: ids(inputs, actor)

  defp message(inputs, actor) do
    assert {:error, %Ash.Error.Invalid{} = error} = CMS.list_pages(inputs, actor: actor)
    Exception.message(error)
  end

  setup do
    admin = admin()
    price = name("price")
    color = name("color")
    define!(%{name: price, field_type: :integer}, admin)
    define!(%{name: color, field_type: :string}, admin)

    # A tag value ties every row to this test; the filters below scope on it.
    tag = name("grp")
    scope = name("scope")
    define!(%{name: scope, field_type: :string}, admin)

    mk = fn title, p, c ->
      page!(title, %{scope => tag, price => p, color => c}, admin)
    end

    rows = %{
      cheap_red: mk.("Cheap red", 5, "red"),
      cheap_blue: mk.("Cheap blue", 5, "blue"),
      dear_red: mk.("Dear red", 50, "red"),
      dear_blue: mk.("Dear blue", 50, "blue")
    }

    %{admin: admin, price: price, color: color, scope: scope, tag: tag, rows: rows}
  end

  defp scoped(ctx, filter), do: %{custom_filter: Map.merge(%{ctx.scope => ctx.tag}, filter)}

  describe "custom_filter groups" do
    test "_or over two custom fields", ctx do
      %{rows: r, admin: admin} = ctx

      filter = %{"_or" => [%{ctx.price => %{"gt" => "10"}}, %{ctx.color => "blue"}]}

      assert Enum.sort(ids(scoped(ctx, filter), admin)) ==
               Enum.sort([r.dear_red.id, r.dear_blue.id, r.cheap_blue.id])
    end

    test "_and, _not and nesting", ctx do
      %{rows: r, admin: admin} = ctx

      assert ids(
               scoped(ctx, %{"_and" => [%{ctx.price => "50"}, %{ctx.color => "red"}]}),
               admin
             ) == [r.dear_red.id]

      assert Enum.sort(ids(scoped(ctx, %{"_not" => %{ctx.color => "red"}}), admin)) ==
               Enum.sort([r.cheap_blue.id, r.dear_blue.id])

      nested = %{
        "_or" => [
          %{"_and" => [%{ctx.price => "5"}, %{ctx.color => "red"}]},
          %{"_not" => %{"_or" => [%{ctx.price => "5"}, %{ctx.color => "red"}]}}
        ]
      }

      assert Enum.sort(ids(scoped(ctx, nested), admin)) ==
               Enum.sort([r.cheap_red.id, r.dear_blue.id])
    end

    test "a position-keyed map is a list (the query-string spelling)", ctx do
      %{rows: r, admin: admin} = ctx

      filter = %{"_or" => %{"0" => %{ctx.price => "5"}, "1" => %{ctx.color => "never"}}}

      assert Enum.sort(ids(scoped(ctx, filter), admin)) ==
               Enum.sort([r.cheap_red.id, r.cheap_blue.id])
    end

    test "_native mixes built-in columns with custom ones", ctx do
      %{rows: r, admin: admin} = ctx

      filter = %{
        "_or" => [
          %{"_native" => %{"title" => "Dear red"}},
          %{ctx.price => "5", "_native" => %{"title" => "Cheap blue"}}
        ]
      }

      assert Enum.sort(ids(scoped(ctx, filter), admin)) ==
               Enum.sort([r.dear_red.id, r.cheap_blue.id])

      assert ids(scoped(ctx, %{"_native" => %{"title" => "Dear blue"}}), admin) ==
               [r.dear_blue.id]
    end

    test "_native only reaches public built-ins", ctx do
      assert message(scoped(ctx, %{"_native" => %{"no_such_column" => "x"}}), ctx.admin) =~
               "_native"
    end

    test "a custom field named or/and/not is untouched by the group keys", ctx do
      %{admin: admin} = ctx
      field = "or"
      define!(%{name: field, field_type: :string}, admin)
      page = page!("Or page", %{field => "yes"}, admin)

      assert ids(%{custom_filter: %{field => "yes"}}, admin) == [page.id]
    end

    test "shape errors name the problem", ctx do
      assert message(scoped(ctx, %{"_or" => []}), ctx.admin) =~ "non-empty list"
      assert message(scoped(ctx, %{"_or" => "x"}), ctx.admin) =~ "non-empty list"
      assert message(scoped(ctx, %{"_not" => []}), ctx.admin) =~ "_not must hold a condition"
      assert message(scoped(ctx, %{"_native" => "x"}), ctx.admin) =~ "_native must be a map"

      assert message(scoped(ctx, %{"_or" => [%{"ghost#{ctx.price}" => "1"}]}), ctx.admin) =~
               "unknown custom field"
    end

    test "groups are bounded", ctx do
      deep = Enum.reduce(1..6, %{ctx.price => "5"}, fn _, acc -> %{"_not" => acc} end)
      assert message(scoped(ctx, deep), ctx.admin) =~ "nest at most"

      wide = %{"_or" => List.duplicate(%{ctx.price => "5"}, 51)}
      assert message(scoped(ctx, wide), ctx.admin) =~ "at most"
    end

    test "a private field is unknown inside a group, as everywhere", ctx do
      %{admin: admin} = ctx
      secret = name("secret")
      define!(%{name: secret, field_type: :string, private: true}, admin)
      page = page!("Hush", %{secret => "x"}, admin)

      filter = %{custom_filter: %{"_or" => [%{secret => "x"}, %{ctx.color => "red"}]}}

      # Below editor (a delivery read: no actor, authorization off) it is the
      # same answer as for a name that was never defined.
      assert {:error, %Ash.Error.Invalid{} = anon} =
               CMS.list_pages(filter, authorize?: false)

      assert {:error, %Ash.Error.Invalid{} = ghost} =
               CMS.list_pages(
                 %{custom_filter: %{"_or" => [%{(secret <> "z") => "x"}]}},
                 authorize?: false
               )

      assert Exception.message(anon) =~ "unknown custom field"
      assert Exception.message(ghost) =~ "unknown custom field"

      # An admin sees it.
      assert page.id in ids(filter, admin)
    end
  end

  describe "mixed order (#2356)" do
    test "_native: lets a built-in token follow a custom one", ctx do
      %{rows: r, admin: admin} = ctx

      sort = "#{ctx.price},_native:title"

      assert sorted_ids(scoped(ctx, %{}) |> Map.put(:custom_sort, sort), admin) ==
               [r.cheap_blue.id, r.cheap_red.id, r.dear_blue.id, r.dear_red.id]

      desc = "-#{ctx.price},-_native:title"

      assert sorted_ids(scoped(ctx, %{}) |> Map.put(:custom_sort, desc), admin) ==
               [r.dear_red.id, r.dear_blue.id, r.cheap_red.id, r.cheap_blue.id]
    end

    test "an unknown built-in is refused", ctx do
      assert message(Map.put(scoped(ctx, %{}), :custom_sort, "_native:nope"), ctx.admin) =~
               "cannot sort by"
    end
  end

  describe "reference and media sorts (#2354)" do
    test "are refused with the reason", ctx do
      %{admin: admin} = ctx
      ref = name("ref")
      media = name("media")
      define!(%{name: ref, field_type: :reference, target_type: "page"}, admin)
      define!(%{name: media, field_type: :media}, admin)

      assert message(%{custom_sort: ref}, admin) =~ "not sortable: its stored label"
      assert message(%{custom_sort: ref}, admin) =~ "cannot read"
      assert message(%{custom_sort: media}, admin) =~ "not sortable: its stored label"
    end
  end
end
