defmodule KilnCMS.CMS.JoinGraduationTest do
  @moduledoc """
  R10 of `docs/relationships-plan.md`: graduating a `:reference` field to a
  typed join resource. The data side, against real edges — the copy the
  generated migration runs, the check that compares edges with join rows,
  and the retirement that deletes the field once the check passes.

  The join table is a throwaway one built here with the columns
  `mix ash.codegen` gives the generated resource (creating a table locks
  nothing that exists), and the resource is the generator's own output,
  compiled under a probe name.

  Not async: retiring holds `content_links` in `SHARE` mode until the test's
  transaction ends, which would make concurrent tests that write edges wait.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentLink
  alias KilnCMS.CMS.JoinGraduation
  alias KilnCMS.Repo

  require Ash.Query

  defp admin! do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "graduation-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "graduation-#{System.unique_integer([:positive])}"

  defp page!(admin, title), do: CMS.create_page!(%{title: title, slug: slug()}, actor: admin)

  defp link_field!(admin, parent, position, attrs) do
    CMS.create_field_definition!(
      Map.merge(attrs, %{link_of_id: parent.id, position: position}),
      actor: admin
    )
  end

  setup do
    admin = admin!()
    name = "ingredients#{System.unique_integer([:positive])}"

    field =
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: name,
          label: "Ingredients",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        actor: admin
      )

    link_field!(admin, field, 0, %{name: "quantity", label: "Quantity", field_type: :integer})

    link_field!(admin, field, 1, %{
      name: "role",
      label: "Role",
      field_type: :select,
      options: ["main", "garnish"],
      default: "main"
    })

    link_field!(admin, field, 2, %{name: "weight", label: "Weight", field_type: :float})
    link_field!(admin, field, 3, %{name: "vegan", label: "Vegan", field_type: :boolean})
    link_field!(admin, field, 4, %{name: "added_on", label: "Added on", field_type: :date})
    link_field!(admin, field, 5, %{name: "checked_at", label: "Checked", field_type: :datetime})

    [flour, sugar, gone] = Enum.map(~w(Flour Sugar Gone), &page!(admin, &1))

    post =
      CMS.create_post!(
        %{
          title: "Cake",
          slug: slug(),
          custom_fields: %{
            name => [
              %{
                "id" => flour.id,
                "link" => %{
                  "quantity" => 2,
                  "weight" => "0.5",
                  "vegan" => true,
                  "added_on" => "2026-10-01",
                  "checked_at" => "2026-10-01T09:30:00"
                }
              },
              %{"id" => sugar.id, "link" => %{"role" => "garnish"}},
              %{"id" => gone.id}
            ]
          }
        },
        actor: admin
      )

    # A purged target leaves a broken edge behind (by design, #1594).
    CMS.purge_page!(gone, actor: admin)

    {:ok, spec} = JoinGraduation.resolve("post.#{name}")
    spec = probe!(spec)

    %{admin: admin, name: name, spec: spec, post: post, flour: flour, sugar: sugar, gone: gone}
  end

  # The join table `ash.codegen` makes of the generated resource, under a
  # throwaway name, and the generated resource compiled against it.
  defp probe!(spec) do
    n = System.unique_integer([:positive])
    table = "graduation_probe_#{n}"

    Repo.query!("""
    CREATE TABLE #{table} (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      org_id uuid NOT NULL,
      source_id uuid NOT NULL,
      target_id uuid NOT NULL,
      position bigint NOT NULL DEFAULT 0,
      quantity bigint,
      role text DEFAULT 'main',
      weight float8,
      vegan boolean,
      added_on date,
      checked_at timestamp(0),
      inserted_at timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      updated_at timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      UNIQUE (org_id, source_id, target_id)
    )
    """)

    module = Module.concat(KilnCMS.CMS, "GraduationProbe#{n}")
    spec = %{spec | table: table, module: module}

    source =
      "defmodule #{inspect(module)} do\n#{Mix.Tasks.Kiln.Gen.Join.resource_body(spec)}\nend\n"

    ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source) end)
    spec
  end

  defp copy!(spec), do: Repo.query!(JoinGraduation.copy_sql(spec)).num_rows

  defp rows(spec) do
    %{rows: rows} =
      Repo.query!("""
      SELECT target_id::text, position, quantity, role, weight, vegan, added_on, checked_at
        FROM #{spec.table} ORDER BY position
      """)

    rows
  end

  defp edges(post, name) do
    ContentLink
    |> Ash.Query.filter(source_id == ^post.id and kind == :reference and field == ^name)
    |> Ash.read!(authorize?: false)
  end

  defp report(spec), do: JoinGraduation.verify(spec, KilnCMS.Accounts.default_org_id())

  describe "the copy" do
    test "moves every edge with its position and typed link values", ctx do
      assert copy!(ctx.spec) == 2

      assert rows(ctx.spec) == [
               [
                 ctx.flour.id,
                 0,
                 2,
                 "main",
                 0.5,
                 true,
                 ~D[2026-10-01],
                 ~N[2026-10-01 09:30:00]
               ],
               [ctx.sugar.id, 1, nil, "garnish", nil, nil, nil, nil]
             ]
    end

    test "skips the broken edge to a purged record, and is safe to run twice", ctx do
      assert copy!(ctx.spec) == 2
      assert copy!(ctx.spec) == 0

      refute Enum.any?(rows(ctx.spec), fn [target | _] -> target == ctx.gone.id end)
      assert length(edges(ctx.post, ctx.name)) == 3
    end

    test "copies within each edge's own organization", ctx do
      copy!(ctx.spec)

      %{rows: [[org_id]]} = Repo.query!("SELECT DISTINCT org_id::text FROM #{ctx.spec.table}")
      assert org_id == KilnCMS.Accounts.default_org_id()
    end
  end

  describe "verify/2" do
    test "counts what the copy took and what it left", ctx do
      assert %{edges: 2, copied: 0, missing: 2, broken: 1, unmirrored: 0, pending: 0} =
               report(ctx.spec)

      copy!(ctx.spec)

      assert %{edges: 2, copied: 2, missing: 0, broken: 1} = report(ctx.spec)
    end

    test "sees a connection made, or a link value changed, after the copy", ctx do
      copy!(ctx.spec)
      [first, second | _] = ctx.post.custom_fields[ctx.name]
      salt = page!(ctx.admin, "Salt")

      {:ok, _post} =
        CMS.update_post(
          ctx.post,
          %{
            custom_fields: %{
              ctx.name => [
                Map.put(first, "link", Map.put(first["link"], "quantity", 3)),
                second,
                %{"id" => salt.id}
              ]
            }
          },
          actor: ctx.admin
        )

      assert %{edges: 3, copied: 1, missing: 2} = report(ctx.spec)
    end
  end

  describe "retire/2" do
    test "refuses, deleting nothing, while connections are missing", ctx do
      assert {:error, %{} = reports} = JoinGraduation.retire(ctx.spec)
      assert %{missing: 2} = reports[KilnCMS.Accounts.default_org_id()]

      assert {:ok, _field} = find_field(ctx)
      assert length(edges(ctx.post, ctx.name)) == 3
    end

    test "refuses while a working copy holds an unpublished value for the field", ctx do
      post = CMS.publish_post!(ctx.post, %{}, actor: ctx.admin)
      copy!(ctx.spec)

      {:ok, _held} =
        CMS.save_post_working_copy(
          post,
          %{fields: %{"custom_fields" => %{ctx.name => [%{"id" => ctx.sugar.id}]}}},
          actor: ctx.admin,
          tenant: post.org_id
        )

      assert {:error, %{} = reports} = JoinGraduation.retire(ctx.spec)
      assert %{pending: 1, missing: 0} = reports[KilnCMS.Accounts.default_org_id()]
    end

    test "a dry run checks and deletes nothing", ctx do
      copy!(ctx.spec)

      assert {:ok, :dry_run, _reports} = JoinGraduation.retire(ctx.spec, dry_run: true)
      assert {:ok, _field} = find_field(ctx)
    end

    test "once the copy is complete, deletes the field, its values and its edges", ctx do
      copy!(ctx.spec)

      assert {:ok, :retired, _reports} = JoinGraduation.retire(ctx.spec)

      assert :error = find_field(ctx)
      assert edges(ctx.post, ctx.name) == []

      post = CMS.get_post!(ctx.post.id, actor: ctx.admin)
      refute Map.has_key?(post.custom_fields, ctx.name)

      # The join rows are the one copy left.
      assert length(rows(ctx.spec)) == 2
    end

    test "refuses a join resource that is not compiled, or lacks a link column", ctx do
      assert {:error, message} =
               JoinGraduation.retire(%{ctx.spec | module: KilnCMS.CMS.NoSuchJoin})

      assert message =~ "KilnCMS.CMS.NoSuchJoin is not compiled"

      extra = %{name: "colour", kind: :string, field_type: :string, required: false, default: nil}

      assert {:error, message} =
               JoinGraduation.retire(%{ctx.spec | columns: [extra | ctx.spec.columns]})

      assert message =~ "has no column for link field(s) colour"
    end
  end

  describe "the mix task" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "prints the check, and --dry-run deletes nothing", ctx do
      copy!(ctx.spec)

      Mix.Task.rerun("kiln.join.retire", [
        "post.#{ctx.name}",
        "--module",
        inspect(ctx.spec.module),
        "--dry-run"
      ])

      assert_received {:mix_shell, :info, [report]}
      assert report =~ "2 of 2 connections copied, 0 missing"
      assert report =~ "1 broken"
      assert_received {:mix_shell, :info, ["Dry run: nothing was deleted."]}
      assert {:ok, _field} = find_field(ctx)
    end

    test "refuses with the counts while connections are missing", ctx do
      assert_raise Mix.Error, ~r/cannot retire yet/, fn ->
        Mix.Task.rerun("kiln.join.retire", [
          "post.#{ctx.name}",
          "--module",
          inspect(ctx.spec.module),
          "--yes"
        ])
      end

      assert {:ok, _field} = find_field(ctx)
    end
  end

  defp find_field(ctx) do
    case CMS.field_definitions_for!(:post, actor: ctx.admin)
         |> Enum.find(&(&1.name == ctx.name)) do
      nil -> :error
      field -> {:ok, field}
    end
  end
end
