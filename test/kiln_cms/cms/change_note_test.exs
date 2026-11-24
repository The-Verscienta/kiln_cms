defmodule KilnCMS.CMS.ChangeNoteTest do
  @moduledoc """
  Why an edit was made (`KilnCMS.CMS.ChangeNotes`): the note given to `:update`,
  `:publish_changes` (and `:publish`, `:restore_version`) lands on that edit's
  version row, and it is required only for a write carrying the editor's
  `require_change_note` marker on a type the site lists.
  """
  # `async: false`: the setting is one row per organization, and these tests
  # all use the default org.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ChangeNotes
  alias KilnCMS.CMS.EditorialSettings

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "note-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "note-#{System.unique_integer([:positive])}"
  defp org, do: KilnCMS.Accounts.default_org_id()

  defp ask_for(admin, types),
    do:
      {:ok, _} = EditorialSettings.save(%{change_note_types: types}, actor: admin, tenant: org())

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp last_version(page, action) do
    CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
    |> Enum.filter(&(&1.version_source_id == page.id and &1.version_action_name == action))
    |> Enum.sort_by(&{DateTime.to_unix(&1.version_inserted_at, :microsecond), &1.id}, :asc)
    |> List.last()
  end

  defp draft(admin), do: CMS.create_page!(%{title: "Draft", slug: slug()}, actor: admin)

  setup do
    %{admin: user(:admin)}
  end

  test "a note on :update lands on that version, trimmed", %{admin: admin} do
    page = draft(admin)

    CMS.update_page!(page, %{seo_title: "Tag", change_note: "  dose fixed per source  "},
      actor: admin
    )

    assert last_version(page, :update).change_note == "dose fixed per source"
  end

  test "a blank note, or none, stores nil", %{admin: admin} do
    page = draft(admin)
    CMS.update_page!(page, %{seo_title: "One", change_note: "   "}, actor: admin)
    assert last_version(page, :update).change_note == nil

    CMS.update_page!(reload(page), %{seo_title: "Two"}, actor: admin)
    assert last_version(page, :update).change_note == nil
  end

  test "Publish changes carries its note", %{admin: admin} do
    page = admin |> draft() |> CMS.publish_page!(%{}, actor: admin) |> reload()

    page =
      page
      |> Ash.Changeset.for_update(:save_working_copy, %{working_title: "Better"}, actor: admin)
      |> Ash.update!()

    page
    |> Ash.Changeset.for_update(:publish_changes, %{change_note: "title clarified"}, actor: admin)
    |> Ash.update!()

    assert last_version(page, :publish_changes).change_note == "title clarified"
  end

  describe "required" do
    test "the editor's marker on a listed type refuses a write without a note",
         %{admin: admin} do
      ask_for(admin, ["page"])
      page = draft(admin)

      assert {:error, error} =
               page
               |> Ash.Changeset.for_update(:update, %{seo_title: "Tag"},
                 actor: admin,
                 context: %{require_change_note: true}
               )
               |> Ash.update()

      assert Exception.message(error) =~ "say why you made this change"

      assert {:ok, _} =
               page
               |> Ash.Changeset.for_update(:update, %{seo_title: "Tag", change_note: "why"},
                 actor: admin,
                 context: %{require_change_note: true}
               )
               |> Ash.update()
    end

    test "without the marker (API, MCP, jobs) a note is never required", %{admin: admin} do
      ask_for(admin, ["page"])
      page = draft(admin)

      assert {:ok, _} = CMS.update_page(page, %{seo_title: "Tag"}, actor: admin)
    end

    test "the marker on a type the site does not list asks nothing", %{admin: admin} do
      ask_for(admin, ["post"])
      page = draft(admin)

      assert {:ok, _} =
               page
               |> Ash.Changeset.for_update(:update, %{seo_title: "Tag"},
                 actor: admin,
                 context: %{require_change_note: true}
               )
               |> Ash.update()
    end

    test "required?/2 reads the site's list", %{admin: admin} do
      ask_for(admin, ["page"])
      assert ChangeNotes.required?(org(), "page")
      refute ChangeNotes.required?(org(), "post")
      refute ChangeNotes.required?(nil, "page")
    end

    test "saving the list keeps the site's other editorial answers", %{admin: admin} do
      {:ok, _} = EditorialSettings.save(%{editors_can_publish: true}, actor: admin, tenant: org())
      ask_for(admin, ["page"])

      assert EditorialSettings.editors_can_publish?(org())
      assert EditorialSettings.change_note_types(org()) == ["page"]
    end
  end
end
