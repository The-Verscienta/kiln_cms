defmodule Kiln.Block.PolicyTest do
  @moduledoc "Phase J — field-/block-level policy declared next to the schema."
  use ExUnit.Case, async: true

  alias Kiln.Block.Policy
  alias KilnCMS.Blocks.{Heading, Quote}

  describe "can_edit_field?/3" do
    test "an editor may edit a Quote's text but not its featured flag" do
      assert Policy.can_edit_field?(Quote, :text, :editor)
      refute Policy.can_edit_field?(Quote, :featured, :editor)
    end

    test "an admin may edit every field, including restricted ones" do
      assert Policy.can_edit_field?(Quote, :featured, :admin)
      assert Policy.can_edit_field?(Quote, :text, :admin)
    end

    test "fields without editable_by are open to any editor" do
      assert Policy.can_edit_field?(Heading, :text, :editor)
      assert Policy.can_edit_field?(Heading, :level, :editor)
    end
  end

  describe "editable_fields/2" do
    test "excludes restricted fields for non-admins" do
      editor_fields = Policy.editable_fields(Quote, :editor)
      assert :text in editor_fields
      assert :citation in editor_fields
      refute :featured in editor_fields

      assert :featured in Policy.editable_fields(Quote, :admin)
    end
  end

  describe "authorize_changes/3" do
    test "rejects a change set touching a forbidden field" do
      assert {:error, [:featured]} = Policy.authorize_changes(Quote, :editor, [:text, :featured])
    end

    test "allows a permitted change set" do
      assert :ok = Policy.authorize_changes(Quote, :editor, [:text, :citation])
      assert :ok = Policy.authorize_changes(Quote, :admin, [:text, :featured])
    end
  end
end
