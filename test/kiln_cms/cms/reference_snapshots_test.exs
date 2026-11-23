defmodule KilnCMS.CMS.ReferenceSnapshotsTest do
  @moduledoc """
  The walkers behind the read-side masking (`KilnCMS.CMS.ReferenceSnapshots`,
  `KilnCMS.Media.Snapshot`) find a snapshot wherever a `:flexible` field's
  items and a `:group` field's rows nest it (#2282), bounded in depth, and
  never take an item for a snapshot.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.ReferenceSnapshots
  alias KilnCMS.Media.Snapshot

  defp ref(id \\ Ecto.UUID.generate()),
    do: %{"id" => id, "type" => "page", "slug" => "s-" <> id, "title" => "T"}

  defp media(id \\ Ecto.UUID.generate()), do: %{"id" => id, "url" => "/u.png", "alt" => "a"}

  defp nest(leaf, 0), do: leaf

  defp nest(leaf, levels),
    do: %{"_id" => Ecto.UUID.generate(), "_type" => "x", "child" => [nest(leaf, levels - 1)]}

  test "snapshots/1 and ids/1 find top-level, listed, item and row snapshots" do
    [a, b, c, d] = for _ <- 1..4, do: ref()

    fields = %{
      "single" => a,
      "many" => [b],
      "sections" => [%{"_id" => "i", "_type" => "t", "cta" => c, "rows" => [%{"cta" => d}]}],
      "pic" => media()
    }

    assert Enum.sort(ReferenceSnapshots.ids(fields)) ==
             Enum.sort(Enum.map([a, b, c, d], & &1["id"]))

    assert length(ReferenceSnapshots.snapshots(fields)) == 4
  end

  test "an item is never a snapshot, whatever its sub-fields are called" do
    item = Map.merge(ref(), %{"_id" => Ecto.UUID.generate(), "_type" => "t"})

    refute ReferenceSnapshots.snapshot?(item)
    assert ReferenceSnapshots.ids(%{"sections" => [item]}) == []
  end

  test "mask/2 nils a hidden single value and drops a hidden list element, at any depth" do
    [hidden, shown] = [ref(), ref()]

    fields = %{
      "sections" => [
        %{
          "_id" => "i",
          "_type" => "t",
          "cta" => hidden,
          "keep" => shown,
          "list" => [hidden, shown]
        }
      ]
    }

    assert %{"sections" => [item]} = ReferenceSnapshots.mask(fields, MapSet.new([shown["id"]]))
    assert item["cta"] == nil
    assert item["keep"] == shown
    assert item["list"] == [shown]
  end

  test "present/2 relabels a readable nested snapshot and masks the rest" do
    [open, closed] = [ref(), ref()]
    labels = %{open["id"] => %{"slug" => "new", "title" => "New"}}
    fields = %{"s" => [%{"_type" => "t", "a" => open, "b" => closed}]}

    assert %{"s" => [%{"a" => %{"slug" => "new", "title" => "New"}, "b" => nil}]} =
             ReferenceSnapshots.present(fields, labels)
  end

  test "the walk stops at max_depth/0; shallower than that is always reached" do
    target = ref()
    max = ReferenceSnapshots.max_depth()

    assert [^target] = ReferenceSnapshots.snapshots(%{"f" => [nest(target, max - 2)]})
    assert ReferenceSnapshots.snapshots(%{"f" => [nest(target, max + 2)]}) == []
  end

  test "non-map custom_fields pass through" do
    assert ReferenceSnapshots.snapshots(nil) == []
    assert ReferenceSnapshots.mask(nil, MapSet.new()) == nil
    assert ReferenceSnapshots.present(%Ash.NotLoaded{}, %{}) == %Ash.NotLoaded{}
  end

  test "Snapshot.ids/1 finds media in items and rows, not in a reference" do
    m = media()
    value = [%{"_type" => "t", "pic" => m, "rows" => [%{"pic" => media()}], "cta" => ref()}]

    assert length(Snapshot.ids(value)) == 2
    assert m["id"] in Snapshot.ids(value)
    assert Snapshot.ids(ref()) == []
  end

  test "Snapshot.refresh/2 rebuilds a nested snapshot and keeps one with no library item" do
    m = media()
    gone = media()
    item = struct(KilnCMS.CMS.MediaItem, id: m["id"], url: "/new.png", alt: "n", variants: %{})

    assert [%{"pic" => fresh, "other" => kept, "txt" => "x"}] =
             Snapshot.refresh(
               [%{"_type" => "t", "pic" => m, "other" => gone, "txt" => "x"}],
               %{m["id"] => item}
             )

    assert fresh["url"] == "/new.png"
    assert kept == gone
  end
end
