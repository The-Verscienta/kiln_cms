defmodule KilnCMS.CMS.VersionDiffTest do
  @moduledoc """
  `VersionDiff` compares two snapshot maps (#467). Pure computation — no database
  involved; the snapshots here are written in the shape
  `KilnCMS.CMS.VersionSnapshot` produces.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.VersionDiff

  defp block(id, type, value),
    do: %{"type" => type, "value" => Map.merge(%{"id" => id, "_type" => type}, value)}

  defp heading(id, text), do: block(id, "heading", %{"level" => 2, "text" => text})

  defp prose(id, text),
    do:
      block(id, "rich_text", %{
        "body" => [%{"_type" => "block", "children" => [%{"_type" => "span", "text" => text}]}]
      })

  defp find_field(diff, name), do: Enum.find(diff.fields, &(&1.name == name))
  defp find_block(diff, key), do: Enum.find(diff.blocks, &(&1.key == key))

  describe "fields" do
    test "reports only the attributes that differ" do
      diff =
        VersionDiff.between(
          %{"title" => "Alpha", "slug" => "same", "locale" => "en"},
          %{"title" => "Beta", "slug" => "same", "locale" => "en"},
          KilnCMS.CMS.Page
        )

      assert [%{name: :title, status: :changed, old: "Alpha", new: "Beta"}] = diff.fields
      assert diff.changed?
    end

    test "two identical snapshots are not a change" do
      snapshot = %{"title" => "Alpha", "blocks" => [heading("a", "Hi")]}
      diff = VersionDiff.between(snapshot, snapshot, KilnCMS.CMS.Page)

      assert diff.fields == []
      refute diff.changed?
    end

    test "filling in a blank field reads as added, clearing it as removed" do
      added =
        VersionDiff.between(
          %{"seo_description" => nil},
          %{"seo_description" => "Now described"},
          KilnCMS.CMS.Page
        )

      assert %{status: :added} = find_field(added, :seo_description)

      removed =
        VersionDiff.between(
          %{"seo_title" => "Was here"},
          %{"seo_title" => ""},
          KilnCMS.CMS.Page
        )

      assert %{status: :removed} = find_field(removed, :seo_title)
    end

    test "long prose fields carry word-level runs that rejoin to the new text" do
      old = String.duplicate("the quick brown fox ", 4) <> "jumps over the lazy dog"
      new = String.duplicate("the quick brown fox ", 4) <> "vaults over the lazy dog"

      diff =
        VersionDiff.between(
          %{"seo_description" => old},
          %{"seo_description" => new},
          KilnCMS.CMS.Page
        )

      field = find_field(diff, :seo_description)

      assert {:del, "jumps"} in field.inline
      assert {:ins, "vaults"} in field.inline

      rejoined =
        field.inline
        |> Enum.reject(fn {op, _text} -> op == :del end)
        |> Enum.map_join(fn {_op, text} -> text end)

      assert rejoined == new
    end

    test "short values are compared whole rather than word by word" do
      diff = VersionDiff.between(%{"slug" => "alpha"}, %{"slug" => "beta"}, KilnCMS.CMS.Page)

      assert %{old: "alpha", new: "beta", inline: nil} = find_field(diff, :slug)
    end

    test "custom_fields diffs key by key" do
      diff =
        VersionDiff.between(
          %{"custom_fields" => %{"kept" => "same", "edited" => "before", "dropped" => "gone"}},
          %{"custom_fields" => %{"kept" => "same", "edited" => "after", "fresh" => "new"}},
          KilnCMS.CMS.Page
        )

      entries = Map.new(find_field(diff, :custom_fields).entries, &{&1.key, &1})

      assert %{status: :changed, old: "before", new: "after"} = entries["edited"]
      assert %{status: :removed} = entries["dropped"]
      assert %{status: :added} = entries["fresh"]
      refute Map.has_key?(entries, "kept")
    end

    test "bookkeeping columns are never diffed" do
      diffable = VersionDiff.diffable_fields(KilnCMS.CMS.Page)

      for hidden <- [:id, :org_id, :lock_version, :search_text, :embedding, :blocks] do
        refute hidden in diffable
      end

      assert :title in diffable
      # Editorially significant fields sort ahead of the alphabetical tail.
      assert Enum.find_index(diffable, &(&1 == :title)) <
               Enum.find_index(diffable, &(&1 == :seo_title))
    end

    test "nothing PaperTrail refuses to track is offered as diffable" do
      # Derived from the resource, not restated: an attribute added to
      # `ignore_attributes` never reaches a snapshot, so diffing it would report
      # it as *removed* on every comparison against the working draft.
      for resource <- [KilnCMS.CMS.Page, KilnCMS.CMS.Post, KilnCMS.CMS.Entry] do
        untracked =
          Ash.Resource.Info.primary_key(resource) ++
            AshPaperTrail.Resource.Info.ignore_attributes(resource)

        diffable = VersionDiff.diffable_fields(resource)

        assert untracked != []

        assert Enum.all?(untracked, &(&1 not in diffable)),
               "#{inspect(resource)} offers untracked attributes: " <>
                 inspect(Enum.filter(untracked, &(&1 in diffable)))
      end
    end

    test "a field that is blank on both sides is not a change" do
      # The fold omits attributes a write never touched, so they read back as
      # `nil`, while `current/1` always emits the attribute's default. Reporting
      # `nil` -> `%{}` renders a "Changed" row whose whole body is an em dash.
      diff =
        VersionDiff.between(
          %{"title" => "Same"},
          %{"title" => "Same", "custom_fields" => %{}, "seo_title" => ""},
          KilnCMS.CMS.Page
        )

      assert diff.fields == []
      refute diff.changed?
    end
  end

  describe "blocks" do
    test "an untouched block is reported as unchanged" do
      blocks = [heading("a", "Hello"), heading("b", "World")]

      diff =
        VersionDiff.between(%{"blocks" => blocks}, %{"blocks" => blocks}, KilnCMS.CMS.Page)

      assert Enum.all?(diff.blocks, &(&1.status == :unchanged))
      refute Enum.any?(diff.blocks, & &1.moved?)
      refute diff.changed?
    end

    test "insertions and deletions keep their position in the tree" do
      diff =
        VersionDiff.between(
          %{"blocks" => [heading("a", "Keep"), heading("b", "Drop")]},
          %{"blocks" => [heading("a", "Keep"), heading("c", "Add")]},
          KilnCMS.CMS.Page
        )

      assert %{status: :unchanged, new_index: 0} = find_block(diff, "a")
      assert %{status: :removed, old_index: 1, new_index: nil} = find_block(diff, "b")
      assert %{status: :added, new_index: 1, old_index: nil} = find_block(diff, "c")
      assert diff.changed?
    end

    test "a reordered block is moved, not deleted and re-added" do
      diff =
        VersionDiff.between(
          %{"blocks" => [heading("a", "One"), heading("b", "Two"), heading("c", "Three")]},
          %{"blocks" => [heading("c", "Three"), heading("a", "One"), heading("b", "Two")]},
          KilnCMS.CMS.Page
        )

      moved = find_block(diff, "c")

      assert moved.moved?
      assert moved.status == :unchanged
      assert moved.old_index == 2
      assert moved.new_index == 0

      # Rendered once, at its new position — not twice.
      assert Enum.count(diff.blocks, &(&1.key == "c")) == 1
      assert diff.changed?
    end

    test "a block that both moved and changed reports both" do
      # Three blocks, not two: with two, pulling either one out explains the swap
      # equally well and Myers is free to pick — with `c` jumping the other two,
      # moving `c` is the only minimal script.
      diff =
        VersionDiff.between(
          %{"blocks" => [heading("a", "One"), heading("b", "Two"), heading("c", "Three")]},
          %{"blocks" => [heading("c", "Three edited"), heading("a", "One"), heading("b", "Two")]},
          KilnCMS.CMS.Page
        )

      block = find_block(diff, "c")

      assert block.moved?
      assert block.status == :changed
      # The prose change is reported as inline runs, not duplicated as a field row.
      assert {:ins, " edited"} in block.inline
    end

    test "block identity ignores schema metadata that always matches" do
      diff =
        VersionDiff.between(
          %{"blocks" => [block("a", "image", %{"url" => "/a.png", "_version" => 1})]},
          %{"blocks" => [block("a", "image", %{"url" => "/b.png", "_version" => 2})]},
          KilnCMS.CMS.Page
        )

      names = Enum.map(find_block(diff, "a").fields, & &1.name)

      assert names == ["url"]
      refute "id" in names
      refute "_type" in names
      refute "_version" in names
    end

    test "a change outside the prose is reported even when the prose is untouched" do
      # The whole point of the view: a heading demoted from h2 to h3 without a
      # word of its text changing. The inline diff is all-`:eq`, so if the field
      # table were suppressed whenever runs exist, this would render a "Changed"
      # pill above an unchanged sentence with nothing indicating what moved.
      diff =
        VersionDiff.between(
          %{"blocks" => [block("a", "heading", %{"text" => "Section one", "level" => 2})]},
          %{"blocks" => [block("a", "heading", %{"text" => "Section one", "level" => 3})]},
          KilnCMS.CMS.Page
        )

      changed = find_block(diff, "a")

      assert changed.status == :changed
      assert [%{name: "level", old: 2, new: 3}] = changed.fields
    end

    test "prose fields aren't repeated as field rows when runs were emitted" do
      diff =
        VersionDiff.between(
          %{"blocks" => [prose("a", "the original sentence")]},
          %{"blocks" => [prose("a", "the replacement sentence")]},
          KilnCMS.CMS.Page
        )

      changed = find_block(diff, "a")

      assert {:ins, "replacement"} in changed.inline
      # `body` is a Portable Text AST; printed beneath its own rendered diff it
      # is unreadable noise.
      refute "body" in Enum.map(changed.fields, & &1.name)
    end

    test "an added block reports its own contents, not just that it appeared" do
      diff =
        VersionDiff.between(
          %{"blocks" => []},
          %{"blocks" => [prose("a", "a brand new pull quote")]},
          KilnCMS.CMS.Page
        )

      # "Quote added" alone tells an editor a block appeared but not what it says.
      assert %{status: :added, inline: [{:ins, "a brand new pull quote"}]} = find_block(diff, "a")
    end

    test "a removed block reports what was lost" do
      diff =
        VersionDiff.between(
          %{"blocks" => [prose("a", "the paragraph that went away")]},
          %{"blocks" => []},
          KilnCMS.CMS.Page
        )

      assert %{status: :removed, inline: [{:del, "the paragraph that went away"}]} =
               find_block(diff, "a")
    end

    test "an added block with no prose still lists its fields" do
      diff =
        VersionDiff.between(
          %{"blocks" => []},
          %{"blocks" => [block("a", "image", %{"url" => "/x.png", "alt" => "A cat"})]},
          KilnCMS.CMS.Page
        )

      added = find_block(diff, "a")

      assert added.status == :added
      assert %{name: "alt", old: nil, new: "A cat"} in added.fields
      assert %{name: "url", old: nil, new: "/x.png"} in added.fields
    end

    test "changed prose carries an inline diff of its flattened text" do
      diff =
        VersionDiff.between(
          %{"blocks" => [prose("a", "the cat sat on the mat")]},
          %{"blocks" => [prose("a", "the cat sat on the rug")]},
          KilnCMS.CMS.Page
        )

      inline = find_block(diff, "a").inline

      assert {:del, "mat"} in inline
      assert {:ins, "rug"} in inline
    end

    test "legacy blocks with no stable id fall back to content identity" do
      old = [%{"type" => "custom", "value" => %{"content" => "<p>a</p>"}}]
      new = [%{"type" => "custom", "value" => %{"content" => "<p>b</p>"}}]

      diff = VersionDiff.between(%{"blocks" => old}, %{"blocks" => new}, KilnCMS.CMS.Page)

      # No id to match on, so this reads as a replacement rather than an edit —
      # but it must not crash, and both sides must be accounted for.
      assert Enum.map(diff.blocks, & &1.status) |> Enum.sort() == [:added, :removed]
    end

    test "repeated identical id-less blocks stay distinguishable" do
      same = %{"type" => "divider", "value" => %{}}

      diff =
        VersionDiff.between(
          %{"blocks" => [same, same]},
          %{"blocks" => [same, same, same]},
          KilnCMS.CMS.Page
        )

      assert length(diff.blocks) == 3
      assert Enum.count(diff.blocks, &(&1.status == :added)) == 1
      assert Enum.count(diff.blocks, &(&1.status == :unchanged)) == 2
    end

    test "a missing or nil block list is an empty tree, not a crash" do
      diff = VersionDiff.between(%{}, %{"blocks" => nil}, KilnCMS.CMS.Page)

      assert diff.blocks == []
      refute diff.changed?
    end
  end

  describe "inline_runs/2" do
    test "an unchanged string is one equal run" do
      assert VersionDiff.inline_runs("same words", "same words") == [{:eq, "same words"}]
    end

    test "a nil side is treated as empty" do
      assert VersionDiff.inline_runs(nil, "added text") == [{:ins, "added text"}]
    end

    test "runs past the token limit are skipped rather than computed" do
      huge = String.duplicate("word ", 2_500)

      assert VersionDiff.inline_runs(huge, huge <> "tail") == nil
    end
  end
end
