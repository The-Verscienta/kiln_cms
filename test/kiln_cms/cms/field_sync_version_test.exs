defmodule KilnCMS.CMS.FieldSyncVersionTest do
  @moduledoc """
  Pins the keys a version-1 field sync document carries (#2656, ADR 0047).

  Every released reader of version 1 (1.9.0 onward) accepts exactly these
  keys and refuses any other as `unknown key(s)`. The lists are read from the
  create actions, so a new attribute on `FieldDefinition`, `FieldSection` or
  `TypeDefinition` changes what an export writes without anyone touching
  `KilnCMS.CMS.FieldSync`. This test is where that change is noticed.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.FieldSync

  # The keys 1.9.0 shipped. Edit these lists only together with a decision.
  @v1_field_keys ~w(
    allow_custom compute default default_field default_source deliver_plain
    deliver_portable field_type format help_text inverse_label inverse_name
    label localization max_items max_sources min_items multiple name
    names_record on_target_delete option_labels options plain_breaks position
    private required required_when schema_org_property searchable section
    target_type target_types validation visible_when widget width
  )

  @v1_section_keys ~w(display initially name)

  @v1_type_keys ~w(
    alias_pattern default_review_after_days description has_excerpt
    has_published_feed icon label name nofollow_default noindex_default
    path_segment plural_label schema_org_type seo_description_pattern
    seo_title_pattern slug_pattern
  )

  test "the document is still version 1" do
    assert FieldSync.version() == 1
  end

  test "a field carries the keys version 1 shipped with" do
    assert_keys(FieldSync.field_keys(), @v1_field_keys, "field")
  end

  test "a section layout carries the keys version 1 shipped with" do
    assert_keys(FieldSync.section_keys(), @v1_section_keys, "section")
  end

  test "a dynamic type's definition carries the keys version 1 shipped with" do
    assert_keys(FieldSync.type_keys(), @v1_type_keys, "type definition")
  end

  defp assert_keys(actual, pinned, what) do
    added = actual -- pinned
    removed = pinned -- actual

    assert added == [] and removed == [], """
    The #{what} keys of a field sync document changed.
      added:   #{inspect(added)}
      removed: #{inspect(removed)}

    A released Kiln refuses a version-1 file carrying a key it does not know,
    and fills a key the file leaves out with the attribute's default. Decide
    before updating the pinned list in #{Path.relative_to_cwd(__ENV__.file)}:

      * leave the attribute out of the document (KilnCMS.CMS.FieldSync drops
        field keys through @owner_keys and section keys through
        @section_owner_keys; a type definition key would need a list of
        its own, since type_keys/0 has none);
      * keep version 1 and accept that older builds refuse new files by the
        unknown key, as docs/field-sync.md describes; or
      * bump the version, with a reader that still accepts every older one
        (FieldSync.parse/1 matches the version exactly today).

    See docs/decisions/0047-the-field-sync-file-stays-version-1-and-a-new-attribute-does-not-bump-it.md.
    """
  end
end
