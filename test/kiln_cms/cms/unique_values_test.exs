defmodule KilnCMS.CMS.UniqueValuesTest do
  @moduledoc """
  The `unique` field constraint (#2276): `KilnCMS.CMS.UniqueValues` on every
  write that puts a value in a record's `custom_fields`, the definition-save
  probe (`Validations.UniqueFieldClean`) and the read-only audit.

  Not async: the dynamic-type cases read the shared type registry, and the
  bulk cases need one connection for the whole batch.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.UniqueValues

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "uv-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "uv-#{System.unique_integer([:positive])}"

  defp unique_field!(admin, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: "sku",
          label: "SKU",
          field_type: :string,
          validation: %{"unique" => true}
        },
        attrs
      ),
      actor: admin
    )
  end

  defp post(admin, sku, extra \\ %{}, opts \\ []) do
    fields = if sku, do: %{"sku" => sku}, else: %{}

    CMS.create_post(
      Map.merge(%{title: "Post #{slug()}", slug: slug(), custom_fields: fields}, extra),
      [actor: admin] ++ opts
    )
  end

  defp post!(admin, sku, extra \\ %{}, opts \\ []) do
    {:ok, post} = post(admin, sku, extra, opts)
    post
  end

  defp message({:error, error}), do: Exception.message(error)

  setup do
    admin = user(:admin)
    unique_field!(admin)
    %{admin: admin}
  end

  describe "single records" do
    test "a second record with the same value is refused, naming the field", %{admin: admin} do
      first = post!(admin, "A-1")

      message = admin |> post("A-1") |> message()
      assert message =~ "SKU (sku) is already in use"

      # An existence oracle otherwise: the other record is never named.
      refute message =~ first.title
      refute message =~ first.slug
      refute message =~ first.id
    end

    test "a different value, or none, is fine; blanks never conflict", %{admin: admin} do
      post!(admin, "A-1")
      assert {:ok, _} = post(admin, "A-2")
      assert {:ok, _} = post(admin, nil)
      assert {:ok, _} = post(admin, nil)
      assert {:ok, _} = post(admin, "")
    end

    test "the match is on the trimmed value and is case-sensitive", %{admin: admin} do
      post!(admin, "A-1")
      assert {:error, _} = post(admin, "  A-1  ")
      assert {:ok, _} = post(admin, "a-1")
    end

    test "a record never conflicts with itself", %{admin: admin} do
      record = post!(admin, "A-1")

      assert {:ok, record} =
               CMS.update_post(record, %{custom_fields: %{"sku" => "A-1"}}, actor: admin)

      assert {:ok, record} = CMS.update_post(record, %{title: "Renamed"}, actor: admin)
      assert record.custom_fields["sku"] == "A-1"
    end

    test "changing to a value another record holds is refused on update", %{admin: admin} do
      post!(admin, "A-1")
      other = post!(admin, "A-2")

      assert other
             |> CMS.update_post(%{custom_fields: %{"sku" => "A-1"}}, actor: admin)
             |> message() =~ "SKU (sku) is already in use"
    end

    test "numbers are compared as numbers", %{admin: admin} do
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "rank",
          label: "Rank",
          field_type: :integer,
          validation: %{"unique" => true}
        },
        actor: admin
      )

      post!(admin, nil, %{custom_fields: %{"rank" => 7}})
      assert {:error, _} = post(admin, nil, %{custom_fields: %{"rank" => "7"}})
      assert {:ok, _} = post(admin, nil, %{custom_fields: %{"rank" => 8}})
    end

    test "a trashed record is ignored; a draft and an archived one count", %{admin: admin} do
      trashed = post!(admin, "T-1")
      CMS.destroy_post!(trashed, actor: admin)
      assert {:ok, _} = post(admin, "T-1")

      # a draft counts
      post!(admin, "D-1")
      assert {:error, _} = post(admin, "D-1")

      # …and so does one the workflow archived
      archived = post!(admin, "R-1")
      archived = CMS.publish_post!(archived, %{}, actor: admin)
      CMS.archive_post!(archived, %{}, actor: admin)
      assert {:error, _} = post(admin, "R-1")
    end

    test "translations may share a value, a locale may not", %{admin: admin} do
      post!(admin, "L-1", %{locale: "en"})
      assert {:ok, es} = post(admin, "L-1", %{locale: "es"})
      assert {:error, _} = post(admin, "L-1", %{locale: "es"})

      # Moving the Spanish variant into English lands in a taken scope, with
      # `custom_fields` untouched.
      assert es |> CMS.update_post(%{locale: "en"}, actor: admin) |> message() =~
               "already in use"
    end

    test "an editor gets the same generic error", %{admin: admin} do
      first = post!(admin, "E-1")
      editor = user(:editor)

      message = editor |> post("E-1") |> message()
      assert message =~ "is already in use"
      refute message =~ first.title
    end
  end

  describe "slug fields (#2433)" do
    setup %{admin: admin} do
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "handle",
          label: "Handle",
          field_type: :slug,
          validation: %{"unique" => true}
        },
        actor: admin
      )

      :ok
    end

    test "a duplicate is refused, compared after tidying", %{admin: admin} do
      post!(admin, nil, %{custom_fields: %{"handle" => "hello-world"}})

      for dup <- ["hello-world", "Hello World!"] do
        assert admin
               |> post(nil, %{custom_fields: %{"handle" => dup}})
               |> message() =~ "Handle (handle) is already in use"
      end

      assert {:ok, _} = post(admin, nil, %{custom_fields: %{"handle" => "hello-there"}})
    end

    test "update to a taken slug is refused; keeping its own is fine", %{admin: admin} do
      post!(admin, nil, %{custom_fields: %{"handle" => "taken"}})
      mine = post!(admin, nil, %{custom_fields: %{"handle" => "mine"}})

      assert {:ok, mine} =
               CMS.update_post(mine, %{custom_fields: %{"handle" => "Mine"}}, actor: admin)

      assert mine.custom_fields["handle"] == "mine"

      assert mine
             |> CMS.update_post(%{custom_fields: %{"handle" => "taken"}}, actor: admin)
             |> message() =~ "already in use"
    end

    test "the unique key is accepted on a slug definition only when single-valued", %{
      admin: admin
    } do
      assert "unique" in KilnCMS.CMS.FieldConstraints.allowed_keys(:slug, nil)

      assert {:error, _} =
               CMS.create_field_definition(
                 %{
                   content_type: :post,
                   name: "handles",
                   label: "Handles",
                   field_type: :slug,
                   multiple: true,
                   validation: %{"unique" => true}
                 },
                 actor: admin
               )
    end
  end

  describe "scope" do
    test "two dynamic types keep their own values", %{admin: admin} do
      a =
        CMS.create_type_definition!(
          %{name: "uva#{System.unique_integer([:positive])}", label: "A"},
          actor: admin
        )

      b =
        CMS.create_type_definition!(
          %{name: "uvb#{System.unique_integer([:positive])}", label: "B"},
          actor: admin
        )

      for type <- [a, b] do
        CMS.create_field_definition!(
          %{
            type_definition_id: type.id,
            name: "code",
            label: "Code",
            field_type: :string,
            validation: %{"unique" => true}
          },
          actor: admin
        )
      end

      entry = fn type, code ->
        CMS.create_entry(
          %{
            title: "E",
            slug: slug(),
            type_definition_id: type.id,
            custom_fields: %{"code" => code}
          },
          actor: admin
        )
      end

      assert {:ok, _} = entry.(a, "X")
      assert {:ok, _} = entry.(b, "X")
      assert {:error, error} = entry.(a, "X")
      assert Exception.message(error) =~ "Code (code) is already in use"
    end

    test "another organization's values are invisible", %{admin: admin} do
      other =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Other",
          slug: "uv-org-#{System.unique_integer([:positive])}",
          status: :active
        })

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "sku",
          label: "SKU",
          field_type: :string,
          validation: %{"unique" => true}
        },
        actor: admin,
        tenant: other
      )

      post!(admin, "O-1")
      assert {:ok, _} = post(admin, "O-1", %{}, tenant: other)
      assert {:error, _} = post(admin, "O-1", %{}, tenant: other)
      assert {:error, _} = post(admin, "O-1")
    end
  end

  describe "the working copy" do
    test "staging is advisory; publishing the copy re-checks and says what to change", %{
      admin: admin
    } do
      live = post!(admin, "W-1")
      live = CMS.publish_post!(live, %{}, actor: admin)

      saved =
        CMS.save_post_working_copy!(live, %{fields: %{"custom_fields" => %{"sku" => "W-2"}}},
          actor: admin
        )

      # Another record takes the staged value before the copy goes live.
      post!(admin, "W-2")

      message = saved |> CMS.publish_post_changes(%{}, actor: admin) |> message()
      assert message =~ "SKU (sku) holds a value another record already uses"
    end

    test "unpublishing folds the copy and surfaces a taken value", %{admin: admin} do
      live = post!(admin, "F-1")
      live = CMS.publish_post!(live, %{}, actor: admin)

      saved =
        CMS.save_post_working_copy!(live, %{fields: %{"custom_fields" => %{"sku" => "F-2"}}},
          actor: admin
        )

      post!(admin, "F-2")
      assert saved |> CMS.unpublish_post(%{}, actor: admin) |> message() =~ "another record"
    end
  end

  describe "restoring" do
    test "a version restore re-checks the value it brings back", %{admin: admin} do
      record = post!(admin, "V-1")
      {:ok, record} = CMS.update_post(record, %{custom_fields: %{"sku" => "V-2"}}, actor: admin)
      post!(admin, "V-1")

      version =
        CMS.list_post_versions!(authorize?: false, tenant: record.org_id)
        |> Enum.filter(&(&1.version_source_id == record.id))
        |> Enum.find(&(&1.changes["custom_fields"] == %{"sku" => "V-1"}))

      assert version

      assert record
             |> CMS.restore_post_version(%{version_id: version.id}, actor: admin)
             |> message() =~
               "another record already uses"
    end

    test "restoring from the trash re-checks", %{admin: admin} do
      record = post!(admin, "R-1")
      CMS.destroy_post!(record, actor: admin)
      post!(admin, "R-1")

      trashed =
        CMS.list_trashed_posts!(actor: admin) |> Enum.find(&(&1.id == record.id))

      assert trashed |> CMS.restore_post(actor: admin) |> message() =~ "another record"
    end

    test "restoring from the trash passes when the value is still free", %{admin: admin} do
      record = post!(admin, "R-2")
      CMS.destroy_post!(record, actor: admin)

      trashed = CMS.list_trashed_posts!(actor: admin) |> Enum.find(&(&1.id == record.id))
      assert {:ok, _} = CMS.restore_post(trashed, actor: admin)
    end
  end

  describe "duplicating" do
    test "a duplicate leaves unique values blank and does not ask for required ones", %{
      admin: admin
    } do
      CMS.update_field_definition!(
        CMS.list_field_definitions!(actor: admin) |> Enum.find(&(&1.name == "sku")),
        %{required: true},
        actor: admin
      )

      source = post!(admin, "C-1")
      {copy, _notes} = KilnCMS.CMS.Duplication.duplicate_with_notes!(:post, source, actor: admin)

      refute Map.has_key?(copy.custom_fields, "sku")
      assert {:ok, _} = post(admin, "C-2")
    end
  end

  describe "bulk" do
    test "two records of one batch with the same value fail the batch", %{admin: admin} do
      inputs = [
        %{title: "B1", slug: slug(), custom_fields: %{"sku" => "B-1"}},
        %{title: "B2", slug: slug(), custom_fields: %{"sku" => "B-1"}}
      ]

      result =
        CMS.create_post(inputs,
          actor: admin,
          bulk_options: [return_errors?: true, return_records?: true, stop_on_error?: true]
        )

      assert result.status == :error
      assert result.error_count > 0
      assert inspect(result.errors) =~ "already in use"
      # The failed batch rolled back whole: the value is still free.
      assert {:ok, _} = post(admin, "B-1")
    end
  end

  describe "enabling unique over duplicates" do
    test "is refused with a count and samples; works once they are distinct", %{admin: admin} do
      field =
        CMS.create_field_definition!(
          %{content_type: :post, name: "slogan", label: "Slogan", field_type: :string},
          actor: admin
        )

      a = post!(admin, nil, %{custom_fields: %{"slogan" => "Same"}})
      post!(admin, nil, %{custom_fields: %{"slogan" => "Same"}})
      post!(admin, nil, %{custom_fields: %{"slogan" => "Other"}})

      assert {:error, error} =
               CMS.update_field_definition(field, %{validation: %{"unique" => true}},
                 actor: admin
               )

      message = Exception.message(error)
      assert message =~ "1 value is shared by several records"
      assert message =~ "\"Same\" ×2"

      CMS.update_post!(a, %{custom_fields: %{"slogan" => "Different"}}, actor: admin)

      assert {:ok, _} =
               CMS.update_field_definition(field, %{validation: %{"unique" => true}},
                 actor: admin
               )
    end

    test "trashed records and other locales do not count", %{admin: admin} do
      field =
        CMS.create_field_definition!(
          %{content_type: :post, name: "slogan", label: "Slogan", field_type: :string},
          actor: admin
        )

      gone = post!(admin, nil, %{custom_fields: %{"slogan" => "Same"}})
      post!(admin, nil, %{custom_fields: %{"slogan" => "Same"}})
      CMS.destroy_post!(gone, actor: admin)
      post!(admin, nil, %{custom_fields: %{"slogan" => "Same"}, locale: "es"})

      assert {:ok, _} =
               CMS.update_field_definition(field, %{validation: %{"unique" => true}},
                 actor: admin
               )
    end
  end

  describe "duplicates/3 (the audit)" do
    test "reports repeated values without writing", %{admin: admin} do
      field =
        CMS.create_field_definition!(
          %{content_type: :post, name: "slogan", label: "Slogan", field_type: :string},
          actor: admin
        )

      post!(admin, nil, %{custom_fields: %{"slogan" => "Same"}})
      post!(admin, nil, %{custom_fields: %{"slogan" => "Same"}})
      post!(admin, nil, %{custom_fields: %{"slogan" => "Once"}})

      scope = %{resource: KilnCMS.CMS.Post, org_id: field.org_id}

      assert %{groups: 1, samples: [%{value: "Same", count: 2}]} =
               UniqueValues.duplicates(scope, "slogan")

      assert %{groups: 0, samples: []} = UniqueValues.duplicates(scope, "sku")
    end
  end

  describe "audit/3 and mix kiln.fields.duplicates" do
    test "lists the unique fields that repeat, per type, and the task fails on them", %{
      admin: admin
    } do
      org_id = KilnCMS.Accounts.default_org_id()
      assert UniqueValues.audit(org_id, "post") == []

      # Slip a repeat past the write path, as raw SQL would.
      a = post!(admin, "AU-1")
      b = post!(admin, "AU-2")

      KilnCMS.Repo.query!(
        "UPDATE posts SET custom_fields = jsonb_build_object('sku', 'AU-1') WHERE id = $1",
        [Ecto.UUID.dump!(b.id)]
      )

      assert [%{type: "post", field: "sku", groups: 1, samples: [%{value: "AU-1", count: 2}]}] =
               UniqueValues.audit(org_id, "post")

      assert UniqueValues.audit(org_id, "page") == []
      refute a.id == b.id

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      assert_raise Mix.Error, ~r/1 unique field/, fn ->
        Mix.Tasks.Kiln.Fields.Duplicates.run(["--type", "post"])
      end

      assert_received {:mix_shell, :info, ["post.sku (SKU): 1 repeated value(s)"]}
    end
  end

  describe "index use" do
    test "the lookup is served by the custom_fields GIN index at scale", %{admin: admin} do
      org_id = admin |> post!(nil) |> Map.fetch!(:org_id)

      KilnCMS.Repo.query!(
        """
        INSERT INTO posts (id, title, slug, locale, state, org_id, custom_fields, blocks, inserted_at, updated_at)
        SELECT gen_random_uuid(), 'p' || g, 'bulk-' || g, 'en', 'draft', $1,
               jsonb_build_object('sku', 'S-' || g), '{}'::jsonb[], now(), now()
        FROM generate_series(1, 4000) g
        """,
        [Ecto.UUID.dump!(org_id)]
      )

      KilnCMS.Repo.query!("ANALYZE posts")

      %{rows: rows} =
        KilnCMS.Repo.query!(
          """
          EXPLAIN SELECT 1 FROM posts
          WHERE org_id = $1 AND archived_at IS NULL AND locale = 'en'
            AND custom_fields @> jsonb_build_object('sku'::text, '"S-77"'::jsonb)
          LIMIT 1
          """,
          [Ecto.UUID.dump!(org_id)]
        )

      plan = Enum.map_join(rows, "\n", &hd/1)
      refute plan =~ "Seq Scan on posts", plan
      assert plan =~ "custom_fields", plan
    end
  end
end
