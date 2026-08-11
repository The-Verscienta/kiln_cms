defmodule KilnCMS.Experiments.AssignmentTest do
  @moduledoc """
  Bucketing and patch application (#499) — the pure half, tested without a
  database so the edge cases are cheap to enumerate.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Experiments.Assignment

  defp variant(id, weight, patch \\ %{}) do
    %KilnCMS.Experiments.Variant{id: id, weight: weight, patch: patch, name: id, control: false}
  end

  @a "11111111-1111-1111-1111-111111111111"
  @b "22222222-2222-2222-2222-222222222222"

  describe "choose/2" do
    test "returns nil when there is nothing to choose" do
      refute Assignment.choose([])
    end

    # An experiment configured to serve nothing serves the canonical document,
    # rather than dividing by zero on the way to deciding that.
    test "returns nil when every weight is zero" do
      refute Assignment.choose([variant(@a, 0), variant(@b, 0)])
    end

    test "a zero-weight arm is never chosen" do
      variants = [variant(@a, 0), variant(@b, 1)]

      for _ <- 1..50 do
        assert Assignment.choose(variants).id == @b
      end
    end

    test "a keyed choice is deterministic" do
      variants = [variant(@a, 1), variant(@b, 1)]
      first = Assignment.choose(variants, "visitor-7")

      for _ <- 1..20 do
        assert Assignment.choose(variants, "visitor-7").id == first.id
      end
    end

    # The same key must land on the same arm across nodes and restarts, so the
    # walk is over an id-sorted list rather than whatever order the database
    # happened to return.
    test "a keyed choice does not depend on the order variants arrive in" do
      forward = [variant(@a, 1), variant(@b, 1)]
      backward = [variant(@b, 1), variant(@a, 1)]

      for key <- ~w(a b c d e f g h) do
        assert Assignment.choose(forward, key).id == Assignment.choose(backward, key).id
      end
    end

    test "keys spread across both arms" do
      variants = [variant(@a, 1), variant(@b, 1)]
      ids = for n <- 1..200, do: Assignment.choose(variants, "visitor-#{n}").id

      assert @a in ids
      assert @b in ids
    end

    test "an empty key falls back to stateless assignment" do
      variants = [variant(@a, 0), variant(@b, 1)]
      assert Assignment.choose(variants, "").id == @b
    end

    test "weights are honoured, roughly" do
      variants = [variant(@a, 9), variant(@b, 1)]
      ids = for n <- 1..1000, do: Assignment.choose(variants, "k#{n}").id

      # A wide band on purpose — this asserts the split is weighted, not that
      # phash2 is uniform.
      assert Enum.count(ids, &(&1 == @a)) > 700
    end
  end

  describe "apply_to_record/2" do
    test "no variant leaves the record alone" do
      record = %{title: "Canonical", excerpt: "As written"}
      assert Assignment.apply_to_record(record, nil) == record
    end

    test "patches only the fields it names" do
      record = %{title: "Canonical", excerpt: "As written"}

      patched =
        Assignment.apply_to_record(record, variant(@a, 1, %{"fields" => %{"title" => "New"}}))

      assert patched.title == "New"
      assert patched.excerpt == "As written"
    end

    # The validation refuses these at write time; this refuses them again at
    # read time. A patch that reached the row some other way — a restored
    # backup, a hand-written insert — must not be able to move a page's slug on
    # delivery.
    test "refuses a field outside the allowlist even if one is stored" do
      record = %{title: "Canonical", slug: "canonical", state: :published}

      patched =
        Assignment.apply_to_record(
          record,
          variant(@a, 1, %{"fields" => %{"slug" => "moved", "state" => "draft"}})
        )

      assert patched.slug == "canonical"
      assert patched.state == :published
    end
  end

  describe "apply_to_blocks/2" do
    test "patches a block by its stable id" do
      blocks = [%{"id" => @a, "_type" => "heading", "text" => "Old"}]

      [patched] =
        Assignment.apply_to_blocks(
          blocks,
          variant(@b, 1, %{"blocks" => %{@a => %{"text" => "New"}}})
        )

      assert patched["text"] == "New"
      assert patched["_type"] == "heading"
    end

    # A positional patch would break the moment an editor drags a block; an
    # id-keyed one does not, which is the whole reason blocks carry a stable id.
    test "survives reordering" do
      patch = variant(@b, 1, %{"blocks" => %{@a => %{"text" => "New"}}})

      reordered = [
        %{"id" => "33333333-3333-3333-3333-333333333333", "text" => "Other"},
        %{"id" => @a, "text" => "Old"}
      ]

      assert [_other, patched] = Assignment.apply_to_blocks(reordered, patch)
      assert patched["text"] == "New"
    end

    test "leaves unmentioned blocks alone" do
      blocks = [%{"id" => @a, "text" => "One"}, %{"id" => @b, "text" => "Two"}]
      [first, second] = Assignment.apply_to_blocks(blocks, variant(@a, 1, %{"blocks" => %{}}))

      assert first["text"] == "One"
      assert second["text"] == "Two"
    end

    # A CTA inside a two-column layout is exactly what anyone would want to test.
    test "recurses into columns children" do
      blocks = [
        %{
          "id" => "44444444-4444-4444-4444-444444444444",
          "_type" => "columns",
          "columns" => [%{"blocks" => [%{"id" => @a, "text" => "Old"}]}]
        }
      ]

      [columns] =
        Assignment.apply_to_blocks(
          blocks,
          variant(@b, 1, %{"blocks" => %{@a => %{"text" => "New"}}})
        )

      assert [%{"blocks" => [child]}] = columns["columns"]
      assert child["text"] == "New"
    end
  end

  describe "apply_to_artifact/2" do
    # The artifact keys blocks by `_id`, not `id` — the same idea in a different
    # shape, which is why this cannot reuse `apply_to_blocks/2`.
    test "patches fields and blocks in the headless shape" do
      body = %{
        "title" => "Canonical",
        "blocks" => [%{"_id" => @a, "_type" => "heading", "text" => "Old"}]
      }

      patched =
        Assignment.apply_to_artifact(
          body,
          variant(@b, 1, %{
            "fields" => %{"title" => "New"},
            "blocks" => %{@a => %{"text" => "Patched"}}
          })
        )

      assert patched["title"] == "New"
      assert [%{"text" => "Patched"}] = patched["blocks"]
    end

    test "refuses a field outside the allowlist" do
      body = %{"title" => "Canonical", "slug" => "canonical", "blocks" => []}

      patched =
        Assignment.apply_to_artifact(body, variant(@a, 1, %{"fields" => %{"slug" => "moved"}}))

      assert patched["slug"] == "canonical"
    end

    test "no variant leaves the body alone" do
      body = %{"title" => "Canonical", "blocks" => []}
      assert Assignment.apply_to_artifact(body, nil) == body
    end
  end
end
