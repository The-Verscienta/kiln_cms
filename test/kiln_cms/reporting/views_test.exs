defmodule KilnCMS.Reporting.ViewsTest do
  @moduledoc """
  The `kiln_reporting_v1` SQL views (#2295, `KilnCMS.Reporting.ViewSql`):
  a BI role reads published, public rows and the custom fields whose live
  definition is neither private nor a `user` field, and nothing else.

  Every leak assertion runs as a throwaway non-superuser role
  (`KilnCMS.ReportingRole`) and scans `row_to_json` of every view for
  sentinel values and for the private field names. The detector is itself
  mutation-tested against a deliberately leaky view, so a detector that
  stops looking fails here instead of passing everything.
  """
  # Not async: each test creates a role and GRANTs on the shared schema, which
  # lock the same catalog rows; two open sandbox transactions doing so deadlock.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.PrivateFields
  alias KilnCMS.ReportingRole

  @motto "SENT-MOTTO-0a1b"

  # One sentinel per private-capable type (`PrivateFields.types/0`), as the
  # JSON text a view would show it. A boolean has no distinctive value; its
  # key name is the sentinel.
  @sentinels %{
    string: "SENT-STRING-7f3a",
    text: "SENT-TEXT-91bc",
    integer: 918_273_645,
    float: 918_273.645,
    boolean: true,
    date: "2031-04-05",
    datetime: "2032-06-07T08:09:10Z",
    url: "https://sent-url.example.com/x",
    select: "SENT-SELECT-55d0"
  }

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rpt-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "rpt-#{System.unique_integer([:positive])}"

  defp field!(admin, attrs, opts \\ []) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, label: "Field", field_type: :string}, attrs),
      [actor: admin] ++ opts
    )
  end

  defp page!(admin, custom_fields, opts \\ []) do
    %{title: "Report #{slug()}", slug: slug(), custom_fields: custom_fields}
    |> CMS.create_page!([actor: admin] ++ opts)
    |> CMS.publish_page!([actor: admin] ++ opts)
  end

  # Puts keys into a stored `custom_fields` that the write path would refuse:
  # the shape a deleted or renamed definition leaves behind.
  defp inject!(table, id, map) do
    KilnCMS.Repo.query!(
      "UPDATE #{table} SET custom_fields = custom_fields || $1::jsonb WHERE id = $2",
      [map, Ecto.UUID.dump!(id)]
    )
  end

  defp private_name(type), do: "secret_#{type}"

  defp needles(user) do
    values =
      for {_type, v} <- @sentinels, v != true, do: to_string(v)

    ["secret_", user.id] ++ values
  end

  defp private_fields!(admin) do
    for {type, _} <- @sentinels do
      attrs = %{name: private_name(type), field_type: type, private: true}

      attrs =
        if type == :select,
          do: Map.put(attrs, :options, [@sentinels.select, "other"]),
          else: attrs

      field!(admin, attrs)
    end
  end

  defp secret_values(admin) do
    for({type, v} <- @sentinels, into: %{}, do: {private_name(type), v})
    |> Map.put("secret_user", admin.id)
  end

  setup do
    admin = admin()
    role = ReportingRole.create!()

    defs =
      [field!(admin, %{name: "secret_user", field_type: :user}), field!(admin, %{name: "motto"})] ++
        private_fields!(admin)

    page = page!(admin, Map.put(secret_values(admin), "motto", @motto))

    %{
      admin: admin,
      role: role,
      page: page,
      needles: needles(admin),
      defs: Map.new(defs, &{&1.name, &1})
    }
  end

  describe "what a view shows" do
    test "the public field and the core columns, never a private value", ctx do
      %{role: role, needles: needles, page: page} = ctx
      dump = ReportingRole.dump(role)

      assert dump["pages"] =~ @motto
      assert dump["pages"] =~ page.id
      assert dump["pages_field_values"] =~ ~s("field_name":"motto")
      assert [] == ReportingRole.leaks(role, needles)
    end

    test "the long view carries the columns the contract names", %{role: role} do
      cols =
        ReportingRole.as(role, fn ->
          KilnCMS.Repo.query!("SELECT * FROM kiln_reporting_v1.pages_field_values LIMIT 0").columns
        end)

      assert cols ==
               ~w(org_id record_id type_name field_name field_type multiple value_text value_json)
    end

    test "the wide view never has search_text, embedding, working_* or the password hash",
         %{role: role} do
      for view <- ~w(pages posts entries) do
        cols =
          ReportingRole.as(role, fn ->
            KilnCMS.Repo.query!("SELECT * FROM kiln_reporting_v1.#{view} LIMIT 0").columns
          end)

        refute Enum.any?(
                 cols,
                 &(&1 in ~w(search_text embedding access_password_hash) or
                     String.starts_with?(&1, "working_"))
               )
      end
    end

    test "value_text is the plain text of a scalar", %{role: role} do
      %{rows: [[text, json]]} =
        ReportingRole.as(role, fn ->
          KilnCMS.Repo.query!(
            "SELECT value_text, value_json::text FROM kiln_reporting_v1.pages_field_values " <>
              "WHERE field_name = 'motto'"
          )
        end)

      assert text == @motto
      assert json == ~s("#{@motto}")
    end
  end

  describe "the private-leak detector" do
    test "a deliberately leaky view is caught (mutation test)", ctx do
      %{role: role, needles: needles} = ctx

      KilnCMS.Repo.query!(
        "CREATE VIEW kiln_reporting_v1.zz_leaky AS SELECT id, custom_fields FROM pages"
      )

      ReportingRole.grant_views!(role)

      leaks = ReportingRole.leaks(role, needles)
      assert Enum.any?(leaks, fn {view, _} -> view == "zz_leaky" end)
      assert {"zz_leaky", "SENT-STRING-7f3a"} in leaks
      refute Enum.any?(leaks, fn {view, _} -> view != "zz_leaky" end)
    end
  end

  describe "the allowlist follows the live definitions" do
    test "flipping a public field to private hides it at once", ctx do
      %{admin: admin, role: role, page: page} = ctx
      flip = field!(admin, %{name: "flip"})

      CMS.update_page!(
        page,
        %{custom_fields: Map.put(page.custom_fields, "flip", "SENT-FLIP-3c")},
        actor: admin
      )

      assert [{"pages", _} | _] = ReportingRole.leaks(role, ["SENT-FLIP-3c"])

      CMS.update_field_definition!(flip, %{private: true}, actor: admin)
      assert [] == ReportingRole.leaks(role, ["SENT-FLIP-3c", "flip"])
    end

    test "renaming a private field leaves its values under a name no definition holds", ctx do
      %{admin: admin, role: role, needles: needles} = ctx

      secret = ctx.defs["secret_string"]

      CMS.update_field_definition!(secret, %{name: "renamed_string"}, actor: admin)
      assert [] == ReportingRole.leaks(role, needles)
    end

    test "renaming a public field moves its values to the new name", ctx do
      %{admin: admin, role: role} = ctx
      motto = ctx.defs["motto"]

      CMS.update_field_definition!(motto, %{name: "moniker"}, actor: admin)

      %{rows: rows} =
        ReportingRole.as(role, fn ->
          KilnCMS.Repo.query!(
            "SELECT field_name, value_text FROM kiln_reporting_v1.pages_field_values " <>
              "WHERE value_text = $1",
            [@motto]
          )
        end)

      assert [["moniker", @motto]] == rows
    end

    test "retyping a private field keeps it private", ctx do
      %{admin: admin, role: role, needles: needles} = ctx

      secret = ctx.defs["secret_string"]

      CMS.update_field_definition!(secret, %{field_type: :text}, actor: admin)
      assert [] == ReportingRole.leaks(role, needles)
    end

    test "deleting a private field leaves an orphaned key that no view shows", ctx do
      %{admin: admin, role: role, needles: needles} = ctx

      for definition <- Map.values(ctx.defs),
          String.starts_with?(definition.name, "secret_") do
        CMS.destroy_field_definition!(definition, actor: admin)
      end

      assert [] == ReportingRole.leaks(role, needles)
    end

    test "deleting a private field and re-creating it as private stays hidden", ctx do
      %{admin: admin, role: role, needles: needles} = ctx

      for definition <- Map.values(ctx.defs),
          String.starts_with?(definition.name, "secret_"),
          definition.field_type != :user do
        CMS.destroy_field_definition!(definition, actor: admin)
        attrs = %{name: definition.name, field_type: definition.field_type, private: true}

        attrs =
          if definition.field_type == :select,
            do: Map.put(attrs, :options, [@sentinels.select, "other"]),
            else: attrs

        field!(admin, attrs)
      end

      assert [] == ReportingRole.leaks(role, needles)
    end

    test "an undefined key is never shown", ctx do
      %{admin: admin, role: role} = ctx
      page = page!(admin, %{})
      inject!("pages", page.id, %{"never_defined" => "SENT-UNDEFINED-9e"})
      assert [] == ReportingRole.leaks(role, ["SENT-UNDEFINED-9e"])
    end
  end

  describe "off-type values after a retype" do
    test "a numeric cast over the long view errors without naming a private value", ctx do
      %{admin: admin, role: role, needles: needles} = ctx
      motto = ctx.defs["motto"]
      CMS.update_field_definition!(motto, %{field_type: :integer}, actor: admin)

      # The old string stays in the record; the cast of it is the analyst's
      # error, and the private strings (also not numbers) must not be reachable
      # by the cast: the qual runs above the allowlist.
      error =
        assert_raise Postgrex.Error, fn ->
          ReportingRole.as(role, fn ->
            KilnCMS.Repo.query!(
              "SELECT 1 FROM kiln_reporting_v1.pages_field_values WHERE value_text::numeric > 0"
            )
          end)
        end

      message = Exception.message(error)
      assert message =~ "invalid input syntax"
      refute Enum.any?(needles, &String.contains?(message, &1))
      assert message =~ @motto
    end

    test "the wide view still lists the retyped field's stored value", ctx do
      %{admin: admin, role: role} = ctx
      motto = ctx.defs["motto"]
      CMS.update_field_definition!(motto, %{field_type: :integer}, actor: admin)

      assert ReportingRole.dump(role)["pages"] =~ @motto
    end
  end

  describe "two sites" do
    test "org A's private price neither hides nor reveals org B's public price", ctx do
      %{admin: admin, role: role} = ctx
      org_a = KilnCMS.OrgFixtures.org("rpt-a")
      org_b = KilnCMS.OrgFixtures.org("rpt-b")

      field!(admin, %{name: "price", private: true}, tenant: org_a.id)
      field!(admin, %{name: "price", field_type: :integer}, tenant: org_b.id)

      page!(admin, %{"price" => "SENT-PRICE-A"}, tenant: org_a.id)
      page!(admin, %{"price" => 4242}, tenant: org_b.id)

      %{rows: rows} =
        ReportingRole.as(role, fn ->
          KilnCMS.Repo.query!(
            "SELECT org_id::text, value_text, field_type FROM kiln_reporting_v1.pages_field_values " <>
              "WHERE field_name = 'price'"
          )
        end)

      assert [[org_b.id, "4242", "integer"]] == rows
      assert [] == ReportingRole.leaks(role, ["SENT-PRICE-A"])
    end

    test "a field of another site does not allow a key on this site's records", ctx do
      %{admin: admin, role: role} = ctx
      org_a = KilnCMS.OrgFixtures.org("rpt-c")
      org_b = KilnCMS.OrgFixtures.org("rpt-d")

      field!(admin, %{name: "only_b"}, tenant: org_b.id)
      page = page!(admin, %{}, tenant: org_a.id)
      inject!("pages", page.id, %{"only_b" => "SENT-CROSS-1d"})

      assert [] == ReportingRole.leaks(role, ["SENT-CROSS-1d"])
    end
  end

  describe "the role" do
    test "cannot read a base table or a definition table", %{role: role} do
      for table <- ~w(pages posts entries field_definitions type_definitions users) do
        error =
          assert_raise Postgrex.Error, fn ->
            ReportingRole.as(role, fn ->
              KilnCMS.Repo.query!("SELECT * FROM public.#{table} LIMIT 1")
            end)
          end

        assert Exception.message(error) =~ "permission denied"
      end
    end

    test "cannot write through a view", %{role: role} do
      for sql <- [
            "INSERT INTO kiln_reporting_v1.pages (id) VALUES (gen_random_uuid())",
            "UPDATE kiln_reporting_v1.pages SET title = 'x'",
            "DELETE FROM kiln_reporting_v1.pages",
            "UPDATE kiln_reporting_v1.pages_field_values SET value_text = 'x'"
          ] do
        assert_raise Postgrex.Error, fn ->
          ReportingRole.as(role, fn -> KilnCMS.Repo.query!(sql) end)
        end
      end
    end

    test "cannot create objects in the reporting schema", %{role: role} do
      error =
        assert_raise Postgrex.Error, fn ->
          ReportingRole.as(role, fn ->
            KilnCMS.Repo.query!("CREATE VIEW kiln_reporting_v1.mine AS SELECT 1")
          end)
        end

      assert Exception.message(error) =~ "permission denied"
    end
  end

  describe "which rows a view shows" do
    defp seed!(attrs) do
      Ash.Seed.seed!(
        KilnCMS.CMS.Page,
        Map.merge(
          %{
            title: "Seed #{slug()}",
            slug: slug(),
            state: :published,
            published_at: DateTime.utc_now(),
            custom_fields: %{"motto" => "SENT-ROW-6a"}
          },
          attrs
        )
      )
    end

    test "only published, live, ungated, public rows", %{role: role} do
      seed!(%{title: "Visible Row"})
      seed!(%{title: "Draft Row", state: :draft})
      seed!(%{title: "Archived Row", archived_at: DateTime.utc_now()})
      seed!(%{title: "Password Row", access_password_hash: "$2b$12$notarealhash"})

      for audience <- KilnCMS.CMS.Audiences.gated() do
        seed!(%{title: "Gated #{audience}", audience: audience})
      end

      %{rows: rows} =
        ReportingRole.as(role, fn ->
          KilnCMS.Repo.query!(
            "SELECT title FROM kiln_reporting_v1.pages WHERE title LIKE '%Row' OR title LIKE 'Gated%'"
          )
        end)

      assert [["Visible Row"]] == rows

      assert [] ==
               ReportingRole.leaks(role, ["Draft Row", "Archived Row", "Password Row", "Gated"])
    end

    test "entries show their type and slug, and only the type's own fields", %{
      admin: admin,
      role: role
    } do
      type =
        CMS.create_type_definition!(
          %{name: "gadget#{System.unique_integer([:positive])}", label: "Gadget"},
          actor: admin
        )

      other =
        CMS.create_type_definition!(
          %{name: "widget#{System.unique_integer([:positive])}", label: "Widget"},
          actor: admin
        )

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "sku", label: "SKU", field_type: :string},
        actor: admin
      )

      CMS.create_field_definition!(
        %{
          type_definition_id: type.id,
          name: "cost",
          label: "Cost",
          field_type: :string,
          private: true
        },
        actor: admin
      )

      CMS.create_field_definition!(
        %{type_definition_id: other.id, name: "other_only", label: "O", field_type: :string},
        actor: admin
      )

      %{
        title: "Gizmo",
        slug: slug(),
        type_definition_id: type.id,
        custom_fields: %{
          "sku" => "SENT-SKU-1",
          "cost" => "SENT-COST-2"
        }
      }
      |> CMS.create_entry!(actor: admin)
      |> CMS.publish_entry!(actor: admin)
      |> then(&inject!("entries", &1.id, %{"other_only" => "SENT-OTHER-3"}))

      %{rows: rows} =
        ReportingRole.as(role, fn ->
          KilnCMS.Repo.query!(
            "SELECT type_name, field_name, value_text FROM kiln_reporting_v1.entries_field_values"
          )
        end)

      assert [[type.name, "sku", "SENT-SKU-1"]] == rows
      assert [] == ReportingRole.leaks(role, ["SENT-COST-2", "SENT-OTHER-3"])

      %{rows: [[type_name, type_slug]]} =
        ReportingRole.as(role, fn ->
          KilnCMS.Repo.query!("SELECT type_name, type_slug FROM kiln_reporting_v1.entries")
        end)

      assert type_name == type.name
      assert is_binary(type_slug)
    end
  end

  describe "reference fields" do
    @draft_title "SENT-DRAFT-TITLE-4d"
    @draft_slug "sent-draft-slug-4d"

    defp draft!(admin, title, slug),
      do: CMS.create_page!(%{title: title, slug: slug}, actor: admin)

    defp ref_values(role, field) do
      ReportingRole.as(role, fn ->
        %{rows: [[text, json, wide]]} =
          KilnCMS.Repo.query!(
            "SELECT v.value_text, v.value_json, p.custom_fields -> $1 " <>
              "FROM kiln_reporting_v1.pages_field_values v " <>
              "JOIN kiln_reporting_v1.pages p ON p.id = v.record_id " <>
              "WHERE v.field_name = $1",
            [field]
          )

        {text, json, wide}
      end)
    end

    test "a reference to a draft exposes its id and type, never its title or slug", ctx do
      %{admin: admin, role: role} = ctx
      target = draft!(admin, @draft_title, @draft_slug)
      field!(admin, %{name: "see", field_type: :reference, target_type: "page"})
      page = page!(admin, %{"see" => target.id})

      # The stored snapshot does carry the draft's label: that is the hazard.
      assert page.custom_fields["see"]["title"] == @draft_title

      assert [] == ReportingRole.leaks(role, [@draft_title, @draft_slug])

      {text, json, wide} = ref_values(role, "see")
      assert text == target.id
      assert json == %{"id" => target.id, "type" => "page"}
      assert wide == json
    end

    test "a list of references exposes ids and types only, in order", ctx do
      %{admin: admin, role: role} = ctx
      a = draft!(admin, @draft_title <> "-a", @draft_slug <> "-a")
      b = draft!(admin, @draft_title <> "-b", @draft_slug <> "-b")
      field!(admin, %{name: "many", field_type: :reference, target_type: "page", multiple: true})
      page!(admin, %{"many" => [b.id, a.id]})

      assert [] == ReportingRole.leaks(role, [@draft_title, @draft_slug])

      {_text, json, wide} = ref_values(role, "many")

      assert json == [%{"id" => b.id, "type" => "page"}, %{"id" => a.id, "type" => "page"}]
      assert wide == json
    end

    test "a snapshot left under a retyped field is cut down too", ctx do
      %{admin: admin, role: role} = ctx
      target = draft!(admin, @draft_title, @draft_slug)
      ref = field!(admin, %{name: "see", field_type: :reference, target_type: "page"})
      page!(admin, %{"see" => target.id})

      CMS.update_field_definition!(ref, %{field_type: :string, target_type: nil}, actor: admin)

      assert [] == ReportingRole.leaks(role, [@draft_title, @draft_slug])
    end

    test "a media snapshot is not mistaken for a reference", %{admin: admin, role: role} do
      field!(admin, %{name: "pic", field_type: :string})
      page = page!(admin, %{})

      snapshot = %{
        "id" => Ecto.UUID.generate(),
        "type" => "image",
        "slug" => "s",
        "title" => "t",
        "url" => "https://cdn.example.com/a.jpg"
      }

      inject!("pages", page.id, %{"pic" => snapshot})

      assert {_text, %{"url" => "https://cdn.example.com/a.jpg"}, _} = ref_values(role, "pic")
    end

    test "off-type data cannot make a view raise", %{admin: admin, role: role} do
      field!(admin, %{name: "see", field_type: :reference, target_type: "page"})
      field!(admin, %{name: "many", field_type: :reference, target_type: "page", multiple: true})
      one = page!(admin, %{})
      two = page!(admin, %{})
      three = page!(admin, %{})

      inject!("pages", one.id, %{"see" => "just a string", "many" => 42})
      inject!("pages", two.id, %{"see" => [1, "x", nil, %{"id" => "y"}], "many" => %{"a" => 1}})
      inject!("pages", three.id, %{"see" => nil, "many" => ["a", [1], nil]})

      assert %{rows: rows} =
               ReportingRole.as(role, fn ->
                 KilnCMS.Repo.query!(
                   "SELECT record_id, field_name, value_text, value_json::text " <>
                     "FROM kiln_reporting_v1.pages_field_values WHERE field_name IN ('see', 'many')"
                 )
               end)

      assert length(rows) >= 6
      assert is_map(ReportingRole.dump(role))
    end
  end

  describe "invariants the views rely on" do
    test "a :group field can never be private, so a group's nested values are never hidden-by-flag" do
      # The allowlist keeps or drops a whole top-level key. A group's object
      # may nest sub-fields; that is safe only while nothing inside it can be
      # private. If :group joins `PrivateFields.types/0`, the views need a
      # per-sub-field filter first.
      refute :group in PrivateFields.types()
      refute :reference in PrivateFields.types()
      refute :media in PrivateFields.types()
      refute :computed in PrivateFields.types()
    end

    test "a group field cannot be created private", %{admin: admin} do
      assert {:error, _} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "grp",
                   label: "G",
                   field_type: :group,
                   private: true
                 },
                 actor: admin
               )
    end

    test "a computed value is not derived from a private field", ctx do
      %{admin: admin, role: role} = ctx

      field!(admin, %{
        name: "echo",
        field_type: :computed,
        compute: "{{ field.secret_string }}"
      })

      page!(admin, %{"secret_string" => @sentinels.string})
      assert [] == ReportingRole.leaks(role, [@sentinels.string])
    end

    # A computed value is stored (and delivered) as a public field of its own.
    # Flipping its source to private does not re-derive it, so the stored copy
    # keeps showing in the views, exactly as it does in the delivery API, until
    # the record is saved again. Recorded as observed: the fix belongs in the
    # flip (re-derive the type's records), not in the views.
    test "FINDING: a stored computed value outlives its source's flip until the next save", ctx do
      %{admin: admin, role: role} = ctx

      field!(admin, %{name: "echo", field_type: :computed, compute: "{{ field.src }}"})
      src = field!(admin, %{name: "src"})
      page = page!(admin, %{"src" => "SENT-SRC-8e"})
      assert page.custom_fields["echo"] == "SENT-SRC-8e"

      CMS.update_field_definition!(src, %{private: true}, actor: admin)

      assert {"pages_field_values", "SENT-SRC-8e"} in ReportingRole.leaks(role, ["SENT-SRC-8e"])

      CMS.update_page!(page, %{title: "Saved again"}, actor: admin)
      assert [] == ReportingRole.leaks(role, ["SENT-SRC-8e"])
    end
  end

  describe "statements" do
    test "carry no destructive verb, backslash or interpolation in `up`" do
      for resource <- [KilnCMS.CMS.Page, KilnCMS.CMS.Post, KilnCMS.CMS.Entry],
          %{name: name, up: up, down: down} <-
            AshPostgres.DataLayer.Info.custom_statements(resource),
          name in [:reporting_schema, :reporting_view, :reporting_field_values_view] do
        refute up =~ ~r/\bDROP\b|\bRENAME\b/i
        refute up =~ "\\"
        refute up =~ "\#{"
        assert down =~ ~r/^(DROP VIEW IF EXISTS|SELECT 1)/
        refute down =~ ~r/CASCADE|DROP SCHEMA/i
      end
    end
  end
end
