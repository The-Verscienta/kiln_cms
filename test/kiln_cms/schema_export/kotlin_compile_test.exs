defmodule KilnCMS.SchemaExport.KotlinCompileTest do
  @moduledoc """
  The Kotlin emitter's output, through the real compiler and a real decode.

  The twin of `KilnCMS.SchemaExport.SwiftCompileTest`: `KotlinTest` checks
  what the emitter writes, and only `kotlinc` with the kotlinx.serialization
  plugin can say it is Kotlin the plugin accepts, and only decoding an
  artifact Kiln actually fired can say the models read what delivery serves.
  So this publishes a `post` with custom fields of every shape a decoder has
  to get right (a repeating `:group`, a multiple `:select` holding a custom
  term, a rich `:text` with its plain rendition, an unset `:media`) and nested
  blocks, fires it, generates `Kiln.kt` for the same site, compiles it with
  `test/support/fixtures/schema_export/kotlin/Main.kt` and runs the result
  over the artifact.

  Tagged `:kotlinc`, which `test_helper.exs` excludes unless `kotlinc` and
  `kotlin` are on `PATH` **and** `KOTLINX_SERIALIZATION_CLASSPATH` names the
  runtime jars — `kotlinc` bundles the serialization compiler plugin but not
  the library. To run it by hand (Homebrew's `kotlin`, or
  https://kotlinlang.org/docs/command-line.html):

      export KOTLINX_SERIALIZATION_CLASSPATH=/path/kotlinx-serialization-core-jvm-1.12.0.jar:/path/kotlinx-serialization-json-jvm-1.12.0.jar
      mix test test/kiln_cms/schema_export/kotlin_compile_test.exs

  CI runs it in `.github/workflows/kotlin-models.yml`, which
  pins the compiler and both jars. Both jars are on Maven Central under
  `org.jetbrains.kotlinx`. The plugin is
  found next to `kotlinc` (`<kotlin home>/lib`); set `KOTLIN_HOME` if your
  install lays it out differently.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Firing.Engine
  alias KilnCMS.SchemaExport

  @moduletag :kotlinc
  # A cold `kotlinc` starts a JVM per call; the default 60 s is close.
  @moduletag timeout: 300_000

  @fixtures Path.expand("../../support/fixtures/schema_export", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln-kotlin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "the checked-in goldens compile", %{dir: dir} do
    for {name, document} <- [
          {"Full", read_json!(Path.join(@fixtures, "full.schema.json"))},
          {"Parity",
           read_json!(Path.expand("../../../clients/js/test/fixtures/schema.json", __DIR__))}
        ] do
      path = Path.join(dir, "#{name}.kt")

      File.write!(
        path,
        SchemaExport.Kotlin.emit(document, package: "kiln.#{String.downcase(name)}")
      )

      {out, status} = kotlinc([path, "-d", Path.join(dir, name)])
      assert status == 0, "#{name}.kt does not compile:\n#{out}"
    end
  end

  # Admin-named custom fields and select options have no charset rules, so the
  # names the emitter has to rescue are compiled, not just string-matched.
  test "keywords, clashes, escapes and shadowing names still compile", %{dir: dir} do
    closed = fn properties, required ->
      %{
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false
      }
    end

    document = %{
      "$defs" => %{
        "block" => %{"oneOf" => [%{"$ref" => "#/$defs/block_type"}]},
        "block_type" =>
          closed.(
            %{
              "_type" => %{"const" => "type"},
              "type" => %{"type" => "string"},
              "class" => %{"type" => "string"},
              "val" => %{"type" => "string"},
              "2fa" => %{"type" => "boolean"},
              "___" => %{"type" => "string"},
              "read time!" => %{"type" => ["number", "null"]},
              "price $" => %{"type" => "number"},
              "mode" => %{
                "enum" => [
                  "Companion",
                  "class",
                  "a_b",
                  "a-b",
                  ~S(C:\x) <> ~s("y\n\u0001 $z),
                  ""
                ]
              },
              "block" =>
                closed.(
                  %{"blocks" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/block"}}},
                  []
                ),
              "string" => closed.(%{"n" => %{"type" => "integer"}}, []),
              "seo" => closed.(%{}, []),
              "SEO" => closed.(%{}, []),
              "where" => closed.(%{}, [])
            },
            ["_type"]
          ),
        "kiln_json" => closed.(%{}, []),
        "document" => %{
          "description" => "Has */ and /* in it.",
          "type" => "object",
          "properties" => %{"x" => %{"type" => "string"}}
        },
        "content_class" => closed.(%{"type" => %{"const" => "class"}}, ["type"])
      }
    }

    path = Path.join(dir, "Awkward.kt")
    File.write!(path, SchemaExport.Kotlin.emit(document, package: "kiln.awkward"))
    {out, status} = kotlinc([path, "-d", Path.join(dir, "awkward")])
    assert status == 0, "Awkward.kt does not compile:\n#{out}"
  end

  test "a fired :json artifact decodes into the generated models", %{dir: dir} do
    actor = admin()
    org_id = KilnCMS.Accounts.default_org_id()
    define_fields!(actor)

    post =
      CMS.create_post!(
        %{
          title: "Chamomile",
          slug: "kotlin-#{System.unique_integer([:positive])}",
          blocks: [
            %{"_type" => "heading", "text" => "Uses", "level" => 2},
            %{"_type" => "rich_text", "legacy_html" => "<p>Body</p>"},
            %{
              "_type" => "columns",
              "columns" => [
                %{"blocks" => [%{"_type" => "quote", "text" => "Calm", "citation" => nil}]},
                %{"blocks" => [%{"_type" => "divider"}]}
              ]
            },
            %{"_type" => "image", "url" => "/a.png", "alt" => "A", "media_id" => nil}
          ],
          custom_fields: %{
            "subtitle" => "Matricaria chamomilla",
            "summary" => "<p>A <strong>gentle</strong> herb.</p>",
            "read_time" => 4,
            "properties" => ["tonic", "calming"],
            "dosages" => [%{"amount" => 2.5, "unit" => "g"}, %{"amount" => 150, "unit" => "ml"}],
            "seo" => %{"title" => "Chamomile tea", "no_index" => false}
          }
        },
        actor: actor
      )

    CMS.publish_post!(post, actor: actor)
    drain_oban()

    {:ok, body} = Engine.read(org_id, :post, post.id, :json)

    # A block type this build of the app has never heard of — what a block
    # added to the site after the app shipped looks like.
    body = Map.update!(body, "blocks", &(&1 ++ [%{"_type" => "future_block", "x" => 1}]))

    kiln = Path.join(dir, "Kiln.kt")
    File.write!(kiln, SchemaExport.Kotlin.emit(SchemaExport.json_schema(org_id: org_id)))
    artifact = Path.join(dir, "artifact.json")
    File.write!(artifact, Jason.encode!(body))

    classes = Path.join(dir, "classes")

    {out, status} =
      kotlinc([kiln, Path.join([@fixtures, "kotlin", "Main.kt"]), "-d", classes])

    assert status == 0, "the generated file did not compile:\n#{out}"

    {output, status} =
      System.cmd("kotlin", ["-cp", classpath(classes), "kiln.MainKt", artifact],
        stderr_to_stdout: true
      )

    assert status == 0, output

    read =
      output
      |> String.split("\n", trim: true)
      |> Map.new(&List.to_tuple(String.split(&1, "=", parts: 2)))

    assert read["title"] == "Chamomile"
    assert read["blocks"] == "heading,rich_text,columns[quote,divider],image,unknown:future_block"
    assert read["subtitle"] == "Matricaria chamomilla"
    assert read["summary_plain"] == "A gentle herb."
    assert read["read_time"] == "4"
    assert read["properties"] == "tonic,calming"
    assert read["dosages"] == "2.5g,150.0ml"
    assert read["seo_title"] == "Chamomile tea"
    assert read["hero"] == "nil"
    assert read["round_trip"] == "true"
  end

  defp define_fields!(actor) do
    define = fn attrs -> CMS.create_field_definition!(attrs, actor: actor) end

    for {name, type, extra} <- [
          {"subtitle", :string, %{}},
          {"summary", :text, %{deliver_plain: true}},
          {"read_time", :integer, %{}},
          {"properties", :select,
           %{options: ["tonic", "bitter"], multiple: true, allow_custom: true}},
          {"hero", :media, %{}}
        ] do
      define.(Map.merge(%{content_type: :post, name: name, label: name, field_type: type}, extra))
    end

    dosages =
      define.(%{
        content_type: :post,
        name: "dosages",
        label: "Dosages",
        field_type: :group,
        multiple: true
      })

    for {name, type, extra} <- [
          {"amount", :float, %{}},
          {"unit", :select, %{options: ["g", "ml"]}}
        ],
        do:
          define.(
            Map.merge(
              %{name: name, label: name, field_type: type, group_of_id: dosages.id},
              extra
            )
          )

    seo = define.(%{content_type: :post, name: "seo", label: "SEO", field_type: :group})

    for {name, type} <- [{"title", :string}, {"no_index", :boolean}],
        do: define.(%{name: name, label: name, field_type: type, group_of_id: seo.id})
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "kotlin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # `-Werror`: a warning in generated code is a defect an app's own
  # `allWarningsAsErrors` build would trip over.
  defp kotlinc(args) do
    System.cmd(
      "kotlinc",
      ["-Werror", "-Xplugin=" <> plugin(), "-cp", runtime_classpath() | args],
      stderr_to_stdout: true
    )
  end

  defp classpath(classes), do: Enum.join([classes, runtime_classpath()], ":")

  defp runtime_classpath, do: System.fetch_env!("KOTLINX_SERIALIZATION_CLASSPATH")

  defp plugin do
    home = System.get_env("KOTLIN_HOME") || kotlin_home()

    # Homebrew's `bin/kotlinc` is a wrapper script over `libexec/`.
    [["lib"], ["libexec", "lib"]]
    |> Enum.map(&Path.join([home | &1] ++ ["kotlinx-serialization-compiler-plugin.jar"]))
    |> Enum.find(&File.exists?/1) || flunk("no kotlinx-serialization plugin under #{home}")
  end

  # `kotlinc` is usually a symlink (Homebrew, /usr/bin); the plugin lives
  # beside the real `bin/`.
  defp kotlin_home do
    "kotlinc" |> System.find_executable() |> resolve() |> Path.dirname() |> Path.dirname()
  end

  defp resolve(path) do
    case File.read_link(path) do
      {:ok, target} -> path |> Path.dirname() |> Path.join(target) |> Path.expand() |> resolve()
      {:error, _} -> path
    end
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
end
