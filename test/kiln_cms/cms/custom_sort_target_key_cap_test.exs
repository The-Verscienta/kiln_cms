defmodule KilnCMS.CMS.CustomSortTargetKeyCapTest do
  @moduledoc """
  A reference sort probes each of its field's target resources per row (cost
  measured in `custom_sort_target_key_benchmark_test.exs`), so a field that
  would probe more than `Relations.max_sort_targets/0` is refused (#2444
  follow-up). Not async: it lowers an application-wide setting.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Preparations.CustomFieldQuery.Relations

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "cstkc-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    {:ok, admin: admin}
  end

  defp field!(admin, attrs) do
    name = "cap#{System.unique_integer([:positive])}"

    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, label: "F", name: name, field_type: :reference}, attrs),
      actor: admin
    )

    name
  end

  defp sort(field, admin), do: CMS.list_pages(%{custom_sort: field}, actor: admin)

  defp lower_cap(n) do
    previous = Application.get_env(:kiln_cms, :reference_sort_max_targets)
    Application.put_env(:kiln_cms, :reference_sort_max_targets, n)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, :reference_sort_max_targets, previous),
        else: Application.delete_env(:kiln_cms, :reference_sort_max_targets)
    end)
  end

  test "the default allows every resource of a default build", %{admin: admin} do
    assert Relations.max_sort_targets() >= 3
    unresolved = field!(admin, %{target_type: "page"})
    assert {:ok, _} = sort(unresolved, admin)
  end

  test "a field with more target types than the cap is refused", %{admin: admin} do
    two = field!(admin, %{target_types: ["page", "post"]})
    one = field!(admin, %{target_type: "page"})
    lower_cap(1)

    assert {:error, error} = sort(two, admin)
    assert Exception.message(error) =~ "targets 2 content types and is not sortable"
    assert Exception.message(error) =~ "at most 1"

    assert {:ok, _} = sort(one, admin)
  end

  test "the unresolved-type fallback counts every content resource", %{admin: admin} do
    field = field!(admin, %{target_types: ["page", "post"]})

    KilnCMS.Repo.query!(
      "UPDATE field_definitions SET target_types = ARRAY['gone_type'] WHERE name = $1",
      [field]
    )

    lower_cap(2)
    assert {:error, error} = sort(field, admin)
    assert Exception.message(error) =~ "targets 3 content types"

    lower_cap(3)
    assert {:ok, _} = sort(field, admin)
  end
end
