defmodule KilnCMSWeb.ScopeParamsTest do
  @moduledoc "The team page's scope pickers → stored scope attributes (#2141)."
  use ExUnit.Case, async: true

  alias KilnCMSWeb.ScopeParams

  @stored %{
    editable_types: ["post", "ghost"],
    readable_types: [],
    field_grants: %{
      "post" => ["title", "author_id"],
      "deleted_type" => [],
      "recipe" => ["title"]
    }
  }

  defp grant_rows(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(%{"grant_mode" => %{}, "grant_type" => %{}, "grant_fields" => %{}}, fn
      {{key, mode, fields}, index}, acc ->
        index = to_string(index)

        acc
        |> put_in(["grant_mode", index], mode)
        |> put_in(["grant_type", index], key)
        |> put_fields(index, fields)
    end)
  end

  defp put_fields(acc, _index, nil), do: acc
  defp put_fields(acc, index, fields), do: put_in(acc, ["grant_fields", index], ["" | fields])

  describe "type axes" do
    test "all stores [] and only stores the ticked list" do
      assert {:ok, params} =
               ScopeParams.normalize(
                 %{
                   "editable_mode" => "all",
                   "editable_types" => ["", "post"],
                   "readable_mode" => "only",
                   "readable_types" => ["", "post", "page"]
                 },
                 ScopeParams.blank()
               )

      assert params["editable_types"] == []
      assert params["readable_types"] == ["post", "page"]
    end

    test "only with nothing ticked is refused, never read as no restriction" do
      assert {:error, %{editable_types: :none_picked}} =
               ScopeParams.normalize(
                 %{"editable_mode" => "only", "editable_types" => [""]},
                 ScopeParams.blank()
               )

      # Unticking every stored name is the same refusal, not a widening to [].
      assert {:error, %{editable_types: :none_picked}} =
               ScopeParams.normalize(
                 %{"editable_mode" => "only", "editable_types" => [""]},
                 @stored
               )
    end

    test "an axis posted without a mode keeps its stored value" do
      assert {:ok, params} =
               ScopeParams.normalize(%{"editable_types" => "page, post"}, @stored)

      assert params["editable_types"] == ["post", "ghost"]
      assert params["readable_types"] == []
    end

    test "only without a posted list keeps the stored list" do
      assert {:ok, params} = ScopeParams.normalize(%{"editable_mode" => "only"}, @stored)
      assert params["editable_types"] == ["post", "ghost"]
    end

    test "an unknown mode is ignored" do
      assert {:ok, params} =
               ScopeParams.normalize(
                 %{"editable_mode" => "everything", "editable_types" => ["", "page"]},
                 @stored
               )

      assert params["editable_types"] == ["post", "ghost"]
    end
  end

  describe "field grants" do
    test "any deletes the key, none stores [] and only stores the ticked fields" do
      params =
        grant_rows([
          {"post", "only", ["blocks", "title"]},
          {"page", "none", nil},
          {"recipe", "any", ["title"]}
        ])

      assert {:ok, %{"field_grants" => grants}} =
               ScopeParams.normalize(params, ScopeParams.blank())

      assert grants == %{"post" => ["blocks", "title"], "page" => []}
    end

    test "only with nothing ticked is refused per key" do
      params = grant_rows([{"post", "only", []}, {"page", "none", nil}])

      assert {:error, errors} = ScopeParams.normalize(params, ScopeParams.blank())
      assert errors == %{{:grant, "post"} => :none_picked}
    end

    test "keys posted without a mode pass through unchanged" do
      params = grant_rows([{"page", "none", nil}])

      assert {:ok, %{"field_grants" => grants}} = ScopeParams.normalize(params, @stored)
      assert grants == Map.put(@stored.field_grants, "page", [])
    end

    test "a raw field_grants value from an older page never reaches the form" do
      assert {:ok, params} =
               ScopeParams.normalize(%{"field_grants" => ~s({"post": ["slug"]})}, @stored)

      assert params["field_grants"] == @stored.field_grants
    end

    test "rows without a key or a known mode are ignored" do
      params = %{
        "grant_mode" => %{"0" => "only", "1" => "bogus", "2" => "none"},
        "grant_type" => %{"0" => "", "1" => "post"},
        "grant_fields" => %{"0" => ["title"]}
      }

      assert {:ok, %{"field_grants" => grants}} = ScopeParams.normalize(params, @stored)
      assert grants == @stored.field_grants
    end

    test "the picker keys are stripped from the result" do
      params = Map.merge(grant_rows([{"post", "none", nil}]), %{"name" => "Blog"})

      assert {:ok, normalized} = ScopeParams.normalize(params, ScopeParams.blank())

      assert Map.keys(normalized) |> Enum.sort() ==
               ~w(editable_types field_grants field_read_grants name readable_types)
    end
  end

  describe "read grants (#2281)" do
    defp read_rows(rows) do
      rows
      |> Enum.with_index()
      |> Enum.reduce(
        %{"grant_read_mode" => %{}, "grant_type" => %{}, "grant_read_fields" => %{}},
        fn {{key, mode, fields}, index}, acc ->
          index = to_string(index)

          acc
          |> put_in(["grant_read_mode", index], mode)
          |> put_in(["grant_type", index], key)
          |> put_read_fields(index, fields)
        end
      )
    end

    defp put_read_fields(acc, _index, nil), do: acc

    defp put_read_fields(acc, index, fields),
      do: put_in(acc, ["grant_read_fields", index], fields)

    @read_stored Map.put(@stored, :field_read_grants, %{
                   "post" => ["custom_fields.secret"],
                   "ghost" => []
                 })

    test "the three modes store three shapes, other keys pass through" do
      params =
        read_rows([
          {"post", "none", nil},
          {"page", "only", ["", "custom_fields.pin"]},
          {"ghost", "any", nil}
        ])

      assert {:ok, %{"field_read_grants" => grants}} = ScopeParams.normalize(params, @read_stored)
      assert grants == %{"post" => [], "page" => ["custom_fields.pin"]}
    end

    test "Only with nothing ticked is refused under its own key" do
      params = read_rows([{"post", "only", [""]}])

      assert {:error, %{{:read_grant, "post"} => :none_picked}} =
               ScopeParams.normalize(params, @read_stored)
    end

    test "a post without read modes leaves the stored grants alone" do
      assert {:ok, %{"field_read_grants" => grants}} =
               ScopeParams.normalize(%{"field_read_grants" => "{}"}, @read_stored)

      assert grants == @read_stored.field_read_grants
    end

    test "the same set keeps the stored list verbatim" do
      stored = Map.put(@stored, :field_read_grants, %{"post" => ["b", "a"]})
      params = read_rows([{"post", "only", ["a", "b"]}])

      assert {:ok, %{"field_read_grants" => %{"post" => ["b", "a"]}}} =
               ScopeParams.normalize(params, stored)
    end
  end

  describe "merge_list/2" do
    test "the same set keeps the stored order verbatim" do
      assert ScopeParams.merge_list(["b", "a"], ["a", "b"]) == ["b", "a"]
    end

    test "kept names stay in stored order and new picks are appended" do
      assert ScopeParams.merge_list(["c", "a", "b"], ["d", "b", "c"]) == ["c", "b", "d"]
    end
  end

  test "an untouched form round-trips the stored value exactly" do
    params =
      Map.merge(
        %{
          "editable_mode" => "only",
          "editable_types" => ["", "ghost", "post"],
          "readable_mode" => "all"
        },
        grant_rows([
          {"post", "only", ["author_id", "title"]},
          {"deleted_type", "none", nil},
          {"recipe", "only", ["title"]},
          {"page", "any", nil}
        ])
      )

    assert {:ok, normalized} = ScopeParams.normalize(params, @stored)
    assert normalized["editable_types"] == @stored.editable_types
    assert normalized["readable_types"] == @stored.readable_types
    assert normalized["field_grants"] == @stored.field_grants
  end
end
