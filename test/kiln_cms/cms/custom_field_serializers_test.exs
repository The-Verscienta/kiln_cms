defmodule KilnCMS.CMS.CustomFieldSerializersTest do
  @moduledoc """
  A static guard for #2281: every module under `lib` that mentions
  `custom_fields` is classified below by how the value reaches a reader, so a
  NEW place that serializes custom fields cannot slip past the read mask
  unnoticed. Add the file to the right list (or write the mask) when this
  fails.

  Classes:

    * `:definition` - names the attribute or describes a field's schema; carries no stored value to a reader.
    * `:mask` - is the masking machinery itself (read mask, version mask, filter/sort refusal, shared decision module).
    * `:masked_read` - serializes or diffs a value that reached it through an Ash read as the actor (`MaskPrivateFields`, `MaskVersionFields`) or a mutation result (`MaskHiddenFields`).
    * `:write_path` - builds or checks the map on a write; `RestoreHiddenFields` keeps hidden values in the row and `EnforceCustomFieldGrants` judges what the editor supplied.
    * `:copy` - copies a record's map into a new one; carries only keys the actor may write (`ContentCopy.custom_fields/3`, `import_attrs/3`).
    * `:system_write` - system copies between a document's own locale variants (`ApplySharedFields`): exempt by decision, the actor's write on the source was the checked one.
    * `:actorless` - runs with no Kiln actor (fired artifacts, webhooks, feeds, search, SQL views): private fields are already dropped there, so a read grant narrows nothing further.
    * `:console` - renders from records the console read as the actor, so already masked; the editor-panel, list-column and export surfaces are step 6 of #2281.
    * `:operator` - an operator task, not a reader.
  """
  use ExUnit.Case, async: true

  @classes %{
    definition: ~w(
      lib/kiln_cms/accounts/org_membership.ex
      lib/kiln_cms/accounts/role.ex
      lib/kiln_cms/accounts/user.ex
      lib/kiln_cms/accounts/validations/field_grants_shape.ex
      lib/kiln_cms/cms.ex
      lib/kiln_cms/cms/changes/bust_type_registry.ex
      lib/kiln_cms/cms/changes/clear_deliver_plain.ex
      lib/kiln_cms/cms/changes/clear_deliver_portable.ex
      lib/kiln_cms/cms/field_access.ex
      lib/kiln_cms/cms/field_conversion.ex
      lib/kiln_cms/cms/field_definition.ex
      lib/kiln_cms/cms/field_sync.ex
      lib/kiln_cms/cms/indexed_custom_fields.ex
      lib/kiln_cms/cms/field_types.ex
      lib/kiln_cms/cms/field_types/computed.ex
      lib/kiln_cms/cms/field_types/geolocation.ex
      lib/kiln_cms/cms/join_graduation.ex
      lib/kiln_cms/cms/name_fields.ex
      lib/kiln_cms/cms/payload_links.ex
      lib/kiln_cms/cms/plain_fields.ex
      lib/kiln_cms/cms/portable_fields.ex
      lib/kiln_cms/cms/private_fields.ex
      lib/kiln_cms/cms/reverse_fields.ex
      lib/kiln_cms/cms/searchable_fields.ex
      lib/kiln_cms/cms/select_terms.ex
      lib/kiln_cms/cms/type_definition.ex
      lib/kiln_cms/cms/validations/payload_link.ex
      lib/kiln_cms/cms/validations/private_field.ex
      lib/kiln_cms/cms/version_fields.ex
      lib/kiln_cms/schema_export.ex
      lib/kiln_cms/schema_export/graphql.ex
      lib/kiln_cms/schema_export/kotlin.ex
      lib/kiln_cms/schema_export/swift.ex
      lib/kiln_cms_web/components/scope_pickers.ex
      lib/kiln_cms_web/components/version_diff_components.ex
      lib/kiln_cms_web/graphql_limits.ex
    ),
    mask: ~w(
      lib/kiln_cms/cms/hidden_fields.ex
      lib/kiln_cms/cms/preparations/custom_field_query.ex
      lib/kiln_cms/cms/preparations/custom_field_query/lists.ex
      lib/kiln_cms/cms/preparations/mask_private_fields.ex
      lib/kiln_cms/cms/preparations/mask_unreadable_references.ex
      lib/kiln_cms/cms/preparations/mask_version_fields.ex
    ),
    masked_read: ~w(
      lib/kiln_cms/cms/calculations/custom_fields_plain.ex
      lib/kiln_cms/cms/calculations/custom_fields_portable.ex
      lib/kiln_cms/cms/calculations/effective_seo.ex
      lib/kiln_cms/cms/changes/restore_version.ex
      lib/kiln_cms/cms/content.ex
      lib/kiln_cms/cms/field_display.ex
      lib/kiln_cms/cms/reference_snapshots.ex
      lib/kiln_cms/cms/version_diff.ex
      lib/kiln_cms/cms/version_snapshot.ex
      lib/kiln_cms_web/controllers/revision_controller.ex
      lib/kiln_cms/cms/working_copy.ex
      lib/kiln_cms/i18n/calculations/inherited_fields.ex
      lib/kiln_cms/portability/csv.ex
      lib/kiln_cms/portability/export.ex
      lib/kiln_cms_web/content_export.ex
      lib/kiln_cms_web/graphql/content_record.ex
      lib/kiln_cms_web/graphql/content_record/notation.ex
      lib/kiln_cms_web/graphql/custom_fields.ex
    ),
    write_path: ~w(
      lib/kiln_cms/cms/dynamic_defaults.ex
      lib/kiln_cms/cms/unique_values.ex
      lib/kiln_cms/cms/changes/apply_custom_fields.ex
      lib/kiln_cms/cms/changes/clear_reference_target.ex
      lib/kiln_cms/cms/changes/enforce_custom_field_grants.ex
      lib/kiln_cms/cms/changes/enforce_field_grants.ex
      lib/kiln_cms/cms/changes/promote_working_copy.ex
      lib/kiln_cms/cms/changes/record_change_severity.ex
      lib/kiln_cms/cms/changes/restore_hidden_fields.ex
      lib/kiln_cms/cms/changes/set_next_occurrence.ex
      lib/kiln_cms/cms/changes/set_search_text.ex
      lib/kiln_cms/cms/changes/sync_field_values.ex
      lib/kiln_cms/cms/changes/sync_reference_links.ex
      lib/kiln_cms/cms/computed/daily_refresh.ex
      lib/kiln_cms/cms/content_link.ex
      lib/kiln_cms/cms/content_links.ex
      lib/kiln_cms/cms/content_links/backfill.ex
      lib/kiln_cms/cms/content_links/target_delete.ex
      lib/kiln_cms/cms/reference_edits.ex
      lib/kiln_cms/cms/slugs.ex
      lib/kiln_cms/i18n/validations/shared_fields_read_only.ex
      lib/kiln_cms/media/resnapshot.ex
      lib/kiln_cms/seo/pattern.ex
      lib/kiln_cms/seo/patterns.ex
      lib/kiln_cms/slug/pattern.ex
      lib/kiln_cms_web/graphql/reference_writes.ex
    ),
    copy: ~w(
      lib/kiln_cms/cms/content_copy.ex
      lib/kiln_cms/cms/duplication.ex
      lib/kiln_cms/cms/translations.ex
      lib/kiln_cms/portability/import.ex
    ),
    system_write: ~w(
      lib/kiln_cms/i18n/changes/apply_shared_fields.ex
      lib/kiln_cms/i18n/field_localization.ex
      lib/kiln_cms/i18n/shared_fields.ex
    ),
    actorless: ~w(
      lib/kiln/plugins/health/notices.ex
      lib/kiln/updates.ex
      lib/kiln_cms/events.ex
      lib/kiln_cms/events/index.ex
      lib/kiln_cms/firing/custom_fields.ex
      lib/kiln_cms/firing/engine.ex
      lib/kiln_cms/firing/live_blog.ex
      lib/kiln_cms/firing/point_in_time.ex
      lib/kiln_cms/firing/references.ex
      lib/kiln_cms/i18n/field_fallback.ex
      lib/kiln_cms/provenance.ex
      lib/kiln_cms/reporting/view_sql.ex
      lib/kiln_cms/search/block_indexer.ex
      lib/kiln_cms/search/name_terms.ex
      lib/kiln_cms/search/term_evidence.ex
      lib/kiln_cms/visual_editing.ex
      lib/kiln_cms_web/artifact_fields.ex
      lib/kiln_cms_web/controllers/artifact_controller.ex
      lib/kiln_cms_web/controllers/calendar_controller.ex
      lib/kiln_cms_web/controllers/feed_controller.ex
      lib/kiln_cms_web/controllers/visual_editing_controller.ex
      lib/kiln_cms_web/event_index.ex
      lib/kiln_cms_web/reference_expansion.ex
      lib/kiln_cms_web/teaser.ex
    ),
    console: ~w(
      lib/kiln_cms_web/components/content_editor/custom_fields_panel.ex
      lib/kiln_cms_web/components/content_editor/inspector_components.ex
      lib/kiln_cms_web/components/content_editor/reference_picker.ex
      lib/kiln_cms_web/live/content_editor/group_rows.ex
      lib/kiln_cms_web/live/content_editor/localization.ex
      lib/kiln_cms_web/live/content_editor/reference_values.ex
      lib/kiln_cms_web/live/content_editor/shared.ex
      lib/kiln_cms_web/live/content_editor_live.ex
      lib/kiln_cms_web/live/editor_live.ex
      lib/kiln_cms_web/live/editor_live/field_cells.ex
      lib/kiln_cms_web/live/field_definition_live.ex
      lib/kiln_cms_web/live/safety_fields_live.ex
    ),
    operator: ~w(
      lib/mix/tasks/kiln.gen.plugin.ex
      lib/mix/tasks/kiln.custom_fields.index.ex
      lib/mix/tasks/kiln.join.retire.ex
      lib/mix/tasks/kiln.links.backfill.ex
      lib/mix/tasks/kiln.migrations.check.ex
    )
  }

  @files for {class, files} <- @classes, file <- files, into: %{}, do: {file, class}

  test "every file that mentions custom_fields is classified" do
    mentioning =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        content = File.read!(path)
        content =~ "custom_fields" or content =~ "customFields"
      end)

    unclassified = mentioning -- Map.keys(@files)

    assert unclassified == [],
           "new place(s) that mention custom_fields; classify them (see the moduledoc) " <>
             "after checking the value cannot reach a restricted editor unmasked: " <>
             inspect(unclassified)
  end

  test "no entry is stale" do
    stale =
      Enum.reject(Map.keys(@files), fn path ->
        File.exists?(path) and
          (File.read!(path) =~ "custom_fields" or File.read!(path) =~ "customFields")
      end)

    assert stale == [], "classified but no longer mentioning custom_fields: #{inspect(stale)}"
  end
end
