defmodule KilnCMS.CMS.FieldConversionTaskTest do
  @moduledoc """
  `mix kiln.fields.convert` itself: flags, output and the JSON report.
  The conversion is `KilnCMS.CMS.FieldConversionTest`'s.
  """
  # async: false — `Mix.shell/1` is global, and other tests read the shell.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "convert-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "convert-#{System.unique_integer([:positive])}"

  defp field!(admin, attrs),
    do: CMS.create_field_definition!(Map.put_new(attrs, :content_type, :post), actor: admin)

  defp post!(%{admin: admin, source: source}, value) do
    CMS.create_post!(%{title: "Herb", slug: slug(), custom_fields: %{source => value}},
      actor: admin
    )
  end

  defp reload(post), do: CMS.get_post!(post.id, authorize?: false)

  setup do
    admin = user(:admin)
    n = System.unique_integer([:positive])

    source =
      field!(admin, %{name: "dosages_json_#{n}", label: "Dosages (old)", field_type: :text})

    group =
      field!(admin, %{name: "dosages_#{n}", label: "Dosages", field_type: :group, multiple: true})

    sub = &field!(admin, Map.merge(%{group_of_id: group.id, content_type: nil}, &1))
    sub.(%{name: "amount", label: "Amount", field_type: :float})

    sub.(%{
      name: "unit",
      label: "Unit",
      field_type: :select,
      options: ["g", "ml"],
      required: true,
      position: 1
    })

    %{admin: admin, source: source.name, group: group.name}
  end

  describe "the mix task" do
    setup ctx do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      %{post: post!(ctx, ~s([{"dose": 2, "unit": "g"}]))}
    end

    test "is a dry run unless --apply, and writes a JSON report", %{post: post} = ctx do
      path = Path.join(System.tmp_dir!(), "convert-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(path) end)
      args = ["post", ctx.source, "--to", ctx.group, "--map", "dose=amount"]

      capture_io(fn -> Mix.Tasks.Kiln.Fields.Convert.run(args ++ ["--report", path]) end)
      assert_received {:mix_shell, :info, ["── DRY RUN" <> _]}
      assert_received {:mix_shell, :info, [dry]}
      assert dry =~ "would convert 1"
      assert dry =~ "--apply"
      assert %{"convertible" => 1, "dry_run?" => true} = path |> File.read!() |> Jason.decode!()
      assert reload(post).custom_fields[ctx.group] == nil

      capture_io(fn -> Mix.Tasks.Kiln.Fields.Convert.run(args ++ ["--apply"]) end)
      assert_received {:mix_shell, :info, [applied]}
      assert applied =~ "converted 1"
      assert reload(post).custom_fields[ctx.group] == [%{"amount" => 2.0, "unit" => "g"}]
    end

    test "refuses to write while a record is invalid", ctx do
      post!(ctx, "Two grams")

      assert_raise Mix.Error, ~r/1 invalid record\(s\); nothing written/, fn ->
        capture_io(fn ->
          Mix.Tasks.Kiln.Fields.Convert.run([
            "post",
            ctx.source,
            "--to",
            ctx.group,
            "--map",
            "dose=amount",
            "--apply"
          ])
        end)
      end
    end

    test "a trashed record that does not fit is reported, and does not block --apply",
         %{post: post} = ctx do
      trashed = post!(ctx, "Two grams")
      :ok = CMS.destroy_post!(trashed, actor: ctx.admin)

      capture_io(fn ->
        Mix.Tasks.Kiln.Fields.Convert.run([
          "post",
          ctx.source,
          "--to",
          ctx.group,
          "--map",
          "dose=amount",
          "--apply"
        ])
      end)

      assert_received {:mix_shell, :info, [applied]}
      assert applied =~ "converted 1 (0 published, 0 trashed)"
      assert applied =~ "#{trashed.id} (#{trashed.slug}) (trashed) — unparseable:"
      assert reload(post).custom_fields[ctx.group] == [%{"amount" => 2.0, "unit" => "g"}]
    end

    test "counts only the live invalid records when it refuses", ctx do
      post!(ctx, "Two grams")
      trashed = post!(ctx, "Three grams")
      :ok = CMS.destroy_post!(trashed, actor: ctx.admin)

      assert_raise Mix.Error, ~r/^1 invalid record\(s\); nothing written/, fn ->
        capture_io(fn ->
          Mix.Tasks.Kiln.Fields.Convert.run([
            "post",
            ctx.source,
            "--to",
            ctx.group,
            "--map",
            "dose=amount",
            "--apply"
          ])
        end)
      end
    end

    test "--map takes OLD=NEW", ctx do
      assert_raise Mix.Error, ~r/--map takes OLD=NEW/, fn ->
        Mix.Tasks.Kiln.Fields.Convert.run(["post", ctx.source, "--to", ctx.group, "--map", "x"])
      end
    end
  end
end
