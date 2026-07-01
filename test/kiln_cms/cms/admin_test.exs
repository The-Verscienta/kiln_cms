defmodule KilnCMS.CMS.AdminTest do
  @moduledoc """
  Locks in the content-focused AshAdmin overrides (issue #25): friendly
  datatable columns, resource grouping, trimmed action lists, and the nil-safe
  datetime formatter the admin views use.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.{Admin, MediaItem, Page, Post}

  describe "format_datetime/1" do
    test "renders a compact UTC string for datetimes" do
      assert Admin.format_datetime(~U[2026-06-25 09:05:00Z]) == "2026-06-25 09:05 UTC"
      assert Admin.format_datetime(~N[2026-06-25 09:05:00]) == "2026-06-25 09:05 UTC"
    end

    test "renders nil as a blank string instead of crashing" do
      # AshAdmin calls the formatter even for nil columns (e.g. an unpublished
      # record's published_at), so this must never raise.
      assert Admin.format_datetime(nil) == ""
    end
  end

  describe "content resources are content-focused in the admin" do
    for resource <- [Page, Post] do
      @resource resource

      test "#{inspect(resource)} datatable shows editorial columns, not internals" do
        columns = AshAdmin.Resource.table_columns(@resource)

        # `:state` is deliberately absent — see the comment on `table_columns`
        # in KilnCMS.CMS.Content (commit 24d60d9): on a clean compile,
        # AshStateMachine adds `:state` *after* AshAdmin's ValidateTableColumns
        # transformer runs, so listing it here raises "Invalid table columns".
        # `:published_at` conveys publish status in the table instead.
        assert columns == [:title, :slug, :audience, :locale, :published_at, :updated_at]

        # Internal/search/embedding plumbing stays out of the table.
        for internal <- [
              :search_text,
              :embedding,
              :embedded_at,
              :lock_version,
              :published_version_id
            ] do
          refute internal in columns
        end
      end

      test "#{inspect(resource)} is grouped and labeled by title" do
        assert AshAdmin.Resource.resource_group(@resource) == :content
        assert AshAdmin.Resource.label_field(@resource) == :title
        assert AshAdmin.Resource.relationship_display_fields(@resource) == [:title]
      end

      test "#{inspect(resource)} hides internal write actions from the admin" do
        updates = AshAdmin.Resource.update_actions(@resource)

        assert :publish in updates
        # Scheduler-/worker-driven writes are not surfaced for manual use.
        refute :set_embedding in updates
        refute :set_published_version_id in updates
        refute :publish_scheduled in updates
      end
    end

    test "MediaItem datatable hides the raw variants map and storage pointer" do
      columns = AshAdmin.Resource.table_columns(MediaItem)

      assert columns == [
               :filename,
               :content_type,
               :byte_size,
               :width,
               :height,
               :alt,
               :inserted_at
             ]

      refute :variants in columns
      refute :storage_key in columns

      assert AshAdmin.Resource.resource_group(MediaItem) == :content
      assert AshAdmin.Resource.label_field(MediaItem) == :filename
    end
  end
end
