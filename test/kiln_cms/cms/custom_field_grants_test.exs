defmodule KilnCMS.CMS.CustomFieldGrantsTest do
  @moduledoc """
  Per-custom-field write grants and read restrictions (#2281), at the Ash
  level: `Changes.EnforceCustomFieldGrants` (the write matrix),
  `Changes.RestoreHiddenFields` (a write built on a masked record leaves the
  hidden values alone) and the restore refusal.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "cfg-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp editor(write \\ nil, read \\ nil) do
    user(:editor, %{
      field_grants: if(write, do: %{"post" => write}, else: %{}),
      field_read_grants: if(read, do: %{"post" => read}, else: %{})
    })
  end

  defp slug, do: "cfg-#{System.unique_integer([:positive])}"

  defp field!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :post, label: "Field", field_type: :string}, attrs),
      actor: admin
    )
  end

  setup do
    admin = user(:admin)

    field!(admin, %{name: "notes"})
    field!(admin, %{name: "summary"})
    field!(admin, %{name: "secret", private: true})
    field!(admin, %{name: "other_secret", private: true})

    group = field!(admin, %{name: "dosages", field_type: :group, multiple: true})

    for {name, type} <- [{"amount", :float}, {"unit", :string}] do
      field!(admin, %{name: name, field_type: type, group_of_id: group.id, content_type: nil})
    end

    post =
      CMS.create_post!(
        %{
          title: "Herb",
          slug: slug(),
          custom_fields: %{
            "notes" => "n",
            "summary" => "s",
            "secret" => "SECRET",
            "other_secret" => "OTHER",
            "dosages" => [%{"amount" => 1.0, "unit" => "g"}]
          }
        },
        actor: admin
      )

    %{admin: admin, post: post}
  end

  defp put_fields(post, fields, actor),
    do: CMS.update_post(post, %{custom_fields: fields}, actor: actor)

  defp refused?({:error, %Ash.Error.Invalid{} = error}, key),
    do: Exception.message(error) =~ key and Exception.message(error) =~ "field grant"

  defp refused?(_other, _key), do: false

  describe "writing under a per-key grant" do
    test "a granted key is allowed, an ungranted one refused", %{post: post} do
      editor = editor(["custom_fields.notes"])

      assert {:ok, updated} = put_fields(post, %{"notes" => "changed"}, editor)
      assert updated.custom_fields["notes"] == "changed"

      assert refused?(
               put_fields(updated, %{"summary" => "changed"}, editor),
               "custom_fields.summary"
             )
    end

    test "resubmitting an unchanged ungranted key is not a violation", %{post: post} do
      editor = editor(["custom_fields.notes"])

      assert {:ok, updated} =
               put_fields(
                 post,
                 %{"notes" => "changed", "summary" => "s", "secret" => "SECRET"},
                 editor
               )

      assert updated.custom_fields["notes"] == "changed"
    end

    test "a sibling key changed in the same write is refused", %{post: post} do
      editor = editor(["custom_fields.notes"])

      assert refused?(
               put_fields(post, %{"notes" => "changed", "summary" => "sneaky"}, editor),
               "custom_fields.summary"
             )

      assert CMS.get_post!(post.id, actor: editor).custom_fields["notes"] == "n"
    end

    test "a stale-format resubmission of the same value is not a change", %{post: post} do
      editor = editor(["custom_fields.notes"])
      # The form posts numbers as strings.
      assert {:ok, _} =
               put_fields(
                 post,
                 %{"dosages" => [%{"amount" => "1.0", "unit" => "g"}], "notes" => "x"},
                 editor
               )
    end

    test "the bare custom_fields key still grants everything", %{post: post} do
      editor = editor(["custom_fields"])
      assert {:ok, _} = put_fields(post, %{"summary" => "changed"}, editor)
    end

    test "a title-only grant still refuses custom_fields (the old rule)", %{post: post} do
      editor = editor(["title"])
      assert {:error, %Ash.Error.Invalid{}} = put_fields(post, %{"summary" => "changed"}, editor)
    end

    test "an admin is exempt, and so is a write without an actor", %{post: post, admin: admin} do
      assert {:ok, _} = put_fields(post, %{"summary" => "by admin"}, admin)
      post = CMS.get_post!(post.id, authorize?: false)

      assert {:ok, _} =
               CMS.update_post(post, %{custom_fields: %{"summary" => "x"}}, authorize?: false)
    end
  end

  describe "group fields" do
    test "a sub-field grant covers that key in every row, not the others or the rows", %{
      post: post
    } do
      editor = editor(["custom_fields.dosages.unit"])
      row = %{"amount" => 1.0, "unit" => "ml"}

      assert {:ok, updated} = put_fields(post, %{"dosages" => [row]}, editor)
      assert [%{"unit" => "ml"}] = updated.custom_fields["dosages"]

      assert refused?(
               put_fields(updated, %{"dosages" => [%{"amount" => 9.0, "unit" => "ml"}]}, editor),
               "custom_fields.dosages.amount"
             )

      # Adding a row is a change to the group, not to one sub-field.
      assert refused?(
               put_fields(updated, %{"dosages" => [row, row]}, editor),
               "custom_fields.dosages"
             )
    end

    test "a group grant covers rows added and removed", %{post: post} do
      editor = editor(["custom_fields.dosages"])
      rows = [%{"amount" => 1.0, "unit" => "g"}, %{"amount" => 2.0, "unit" => "ml"}]

      assert {:ok, updated} = put_fields(post, %{"dosages" => rows}, editor)
      assert length(updated.custom_fields["dosages"]) == 2
      assert {:ok, _} = put_fields(updated, %{"dosages" => []}, editor)
    end
  end

  describe "creating under a grant" do
    test "an editor holding a per-key grant is held to it", %{} do
      editor = editor(["custom_fields.notes"])

      assert {:ok, post} =
               CMS.create_post(
                 %{title: "T", slug: slug(), custom_fields: %{"notes" => "ok", "summary" => ""}},
                 actor: editor
               )

      assert post.custom_fields["notes"] == "ok"

      assert refused?(
               CMS.create_post(
                 %{title: "T", slug: slug(), custom_fields: %{"summary" => "no"}},
                 actor: editor
               ),
               "custom_fields.summary"
             )
    end

    test "a whole-attribute grant leaves creates ungoverned" do
      editor = editor(["title"])

      assert {:ok, _} =
               CMS.create_post(
                 %{title: "T", slug: slug(), custom_fields: %{"summary" => "free"}},
                 actor: editor
               )
    end
  end

  describe "hidden (private) fields" do
    test "an editor with an empty read grant cannot write a private field", %{post: post} do
      editor = editor(nil, [])

      assert refused?(put_fields(post, %{"secret" => "new"}, editor), "custom_fields.secret")
      assert {:ok, _} = put_fields(post, %{"notes" => "fine"}, editor)

      assert refused?(
               CMS.create_post(
                 %{title: "T", slug: slug(), custom_fields: %{"secret" => "new"}},
                 actor: editor
               ),
               "custom_fields.secret"
             )

      assert {:ok, _} =
               CMS.create_post(
                 %{title: "T", slug: slug(), custom_fields: %{"notes" => "n", "secret" => ""}},
                 actor: editor
               )
    end

    test "a read entry, or a write grant, un-hides a field", %{post: post} do
      assert {:ok, _} =
               put_fields(post, %{"secret" => "new"}, editor(nil, ["custom_fields.secret"]))

      post = CMS.get_post!(post.id, authorize?: false)

      assert {:ok, _} =
               put_fields(
                 post,
                 %{"secret" => "newer"},
                 editor(["custom_fields.secret"], [])
               )

      post = CMS.get_post!(post.id, authorize?: false)

      assert refused?(
               put_fields(post, %{"other_secret" => "x"}, editor(nil, ["custom_fields.secret"])),
               "custom_fields.other_secret"
             )
    end

    test "a non-private field is never hidden by a read restriction", %{post: post} do
      assert {:ok, _} = put_fields(post, %{"summary" => "public edit"}, editor(nil, []))
    end

    test "a write built on a masked record leaves the hidden values untouched", %{post: post} do
      editor = editor(nil, [])
      masked = %{post | custom_fields: Map.drop(post.custom_fields, ["secret", "other_secret"])}

      assert {:ok, _updated} = put_fields(masked, %{"notes" => "edited"}, editor)

      reloaded = CMS.get_post!(post.id, actor: user(:admin))
      assert reloaded.custom_fields["other_secret"] == "OTHER"
      assert reloaded.custom_fields["secret"] == "SECRET"
      assert reloaded.custom_fields["notes"] == "edited"
    end

    test "restoring a version is refused for an editor with a read restriction", %{
      post: post,
      admin: admin
    } do
      {:ok, post} = CMS.update_post(post, %{title: "Second"}, actor: admin)

      version =
        CMS.list_post_versions!(authorize?: false, tenant: post.org_id)
        |> Enum.filter(&(&1.version_source_id == post.id))
        |> Enum.min_by(& &1.version_inserted_at, DateTime)

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.restore_post_version(post, %{version_id: version.id}, actor: editor(nil, []))

      assert Exception.message(error) =~ "full field access"

      assert {:ok, _} =
               CMS.restore_post_version(post, %{version_id: version.id}, actor: editor())
    end
  end

  describe "the working copy of a live document" do
    setup %{post: post, admin: admin} do
      %{live: CMS.publish_post!(post, actor: admin)}
    end

    test "held custom fields are judged per key", %{live: live} do
      editor = editor(["custom_fields.notes"])

      assert {:ok, saved} =
               CMS.save_post_working_copy(
                 live,
                 %{fields: %{"custom_fields" => %{"notes" => "held"}}},
                 actor: editor,
                 tenant: live.org_id
               )

      assert saved.working_fields["custom_fields"]["notes"] == "held"

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.save_post_working_copy(
                 live,
                 %{fields: %{"custom_fields" => %{"summary" => "held"}}},
                 actor: editor,
                 tenant: live.org_id
               )

      assert Exception.message(error) =~ "custom_fields.summary"
    end

    test "a masked record's working copy keeps the hidden values", %{live: live, admin: admin} do
      editor = editor(nil, [])
      masked = %{live | custom_fields: Map.drop(live.custom_fields, ["secret", "other_secret"])}

      assert {:ok, saved} =
               CMS.save_post_working_copy(
                 masked,
                 %{fields: %{"custom_fields" => %{"notes" => "held"}}},
                 actor: editor,
                 tenant: live.org_id
               )

      # The returned record is masked for this editor (#2281); the row is not.
      refute Map.has_key?(saved.working_fields["custom_fields"], "secret")

      stored = CMS.get_post!(saved.id, actor: admin)
      assert stored.working_fields["custom_fields"]["secret"] == "SECRET"
      assert stored.working_fields["custom_fields"]["notes"] == "held"
    end
  end
end
