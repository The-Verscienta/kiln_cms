defmodule KilnCMS.CMS.CustomFieldRoundTripTest do
  @moduledoc """
  The general guarantee behind #2677: a value written in one accepted spelling
  is found by `custom_filter` equality in every other spelling a write accepts
  for it — on a single field, on a typed list, and on a reference's link field.

  Field names are unique per test, so a predicate only matches records seeded
  here.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  # {type, extra definition attrs, spellings a write stores as one value}
  @spellings [
    {:color, %{}, ["#FFF", "#fff", "#ffffff", " #FFFFFF "]},
    {:email, %{}, ["a@Example.com", "a@example.com", " a@EXAMPLE.COM "]},
    {:telephone, %{}, ["+44 20 7946 0958", "+442079460958", "0044 (20) 7946-0958"]},
    {:time, %{}, ["9:30", "09:30", " 09:30 "]},
    {:slug, %{}, ["Hello World", "hello-world", "Hello  World!"]},
    {:url, %{}, ["https://x.example", " https://x.example "]},
    {:string, %{}, ["plain", "  plain "]},
    {:select, %{options: ["ny"], option_labels: %{"ny" => "New York"}},
     ["ny", "New York", "new york"]}
  ]

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rt-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define!(attrs, admin) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :page, name: "rt#{System.unique_integer([:positive])}", label: "RT"},
        attrs
      ),
      actor: admin
    )
  end

  defp page!(fields, admin) do
    CMS.create_page!(
      %{title: "RT", slug: "rt-#{System.unique_integer([:positive])}", custom_fields: fields},
      actor: admin
    )
  end

  defp ids(filter, admin),
    do: %{custom_filter: filter} |> CMS.list_pages!(actor: admin) |> Enum.map(& &1.id)

  test "a single field: every spelling finds a value written in any other" do
    admin = admin()

    for {type, extra, spellings} <- @spellings, written <- spellings do
      field = define!(Map.put(extra, :field_type, type), admin)
      page = page!(%{field.name => written}, admin)

      for operand <- spellings do
        assert {type, written, operand, ids(%{field.name => operand}, admin)} ==
                 {type, written, operand, [page.id]}
      end
    end
  end

  test "a typed list: every spelling finds an item written in any other" do
    admin = admin()

    for {type, extra, spellings} <- @spellings,
        type in KilnCMS.CMS.ScalarLists.typed(),
        written <- spellings do
      field = define!(Map.merge(extra, %{field_type: type, multiple: true}), admin)
      page = page!(%{field.name => [written]}, admin)

      for operand <- spellings do
        assert {type, written, operand, ids(%{field.name => operand}, admin)} ==
                 {type, written, operand, [page.id]}
      end
    end
  end

  test "a link field: every spelling finds a connection value written in any other" do
    admin = admin()

    target =
      CMS.create_page!(%{title: "Target", slug: "rt-t-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    for {type, extra, spellings} <- @spellings,
        type in KilnCMS.CMS.FieldDefinition.link_field_types(),
        written <- spellings do
      reference = define!(%{field_type: :reference, target_type: "page"}, admin)

      CMS.create_field_definition!(
        Map.merge(extra, %{
          link_of_id: reference.id,
          name: "detail",
          label: "Detail",
          field_type: type
        }),
        actor: admin
      )

      page =
        page!(%{reference.name => %{"id" => target.id, "link" => %{"detail" => written}}}, admin)

      for operand <- spellings do
        assert {type, written, operand, ids(%{"#{reference.name}.link.detail" => operand}, admin)} ==
                 {type, written, operand, [page.id]}
      end
    end
  end
end
