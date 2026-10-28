defmodule KilnCMS.SchemaExport.SwiftCompileTest do
  @moduledoc """
  The Swift emitter's output, through the real compiler and a real decode.

  `KilnCMS.SchemaExport.SwiftTest` checks what the emitter writes; only
  `swiftc` can say it is Swift, and only decoding an artifact Kiln actually
  fired can say the types read what delivery serves. So this publishes a
  `post` with custom fields of every shape a decoder has to get right (a
  repeating `:group`, a multiple `:select` holding a custom term, a rich
  `:text` with its plain rendition, an unset `:media`) and nested blocks,
  fires it, generates `Kiln.swift` for the same site, compiles it with
  `test/support/fixtures/schema_export/swift/main.swift` and runs the result
  over the artifact.

  Tagged `:swiftc`, which `test_helper.exs` excludes when there is no
  `swiftc` on `PATH`. To run it by hand: install Xcode or the Swift toolchain
  (https://www.swift.org/install/), then

      mix test test/kiln_cms/schema_export/swift_compile_test.exs
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Firing.Engine
  alias KilnCMS.SchemaExport

  @moduletag :swiftc
  # A cold `swiftc` on a CI runner takes a while; the default 60 s is close.
  @moduletag timeout: 300_000

  @fixtures Path.expand("../../support/fixtures/schema_export", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln-swift-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "the checked-in goldens type-check", %{dir: dir} do
    for {name, document} <- [
          {"full", read_json!(Path.join(@fixtures, "full.schema.json"))},
          {"parity",
           read_json!(Path.expand("../../../clients/js/test/fixtures/schema.json", __DIR__))}
        ] do
      path = Path.join(dir, "#{name}.swift")
      File.write!(path, SchemaExport.Swift.emit(document))
      {out, status} = swiftc(["-typecheck", path])
      assert status == 0, "#{name}.swift does not type-check:\n#{out}"
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
              "default" => %{"type" => "string"},
              "self" => %{"type" => "string"},
              "hash_value" => %{"type" => "integer"},
              "2fa" => %{"type" => "boolean"},
              "read time!" => %{"type" => ["number", "null"]},
              "mode" => %{
                "enum" => ["unknown", "default", "a_b", "a-b", ~S(C:\x) <> ~s("y\n\u0001), ""]
              },
              "block" =>
                closed.(
                  %{"blocks" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/block"}}},
                  []
                ),
              "where" => closed.(%{}, [])
            },
            ["_type"]
          ),
        "json_value" => closed.(%{}, []),
        "document" => closed.(%{}, []),
        "content_class" => closed.(%{"type" => %{"const" => "class"}}, ["type"])
      }
    }

    path = Path.join(dir, "Awkward.swift")
    File.write!(path, SchemaExport.Swift.emit(document))
    {out, status} = swiftc(["-typecheck", path])
    assert status == 0, "Awkward.swift does not type-check:\n#{out}"
  end

  test "a fired :json artifact decodes into the generated types", %{dir: dir} do
    actor = admin()
    org_id = KilnCMS.Accounts.default_org_id()
    define_fields!(actor)

    post =
      CMS.create_post!(
        %{
          title: "Chamomile",
          slug: "swift-#{System.unique_integer([:positive])}",
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

    kiln = Path.join(dir, "Kiln.swift")
    File.write!(kiln, SchemaExport.Swift.emit(SchemaExport.json_schema(org_id: org_id)))
    artifact = Path.join(dir, "artifact.json")
    File.write!(artifact, Jason.encode!(body))

    binary = Path.join(dir, "decode")

    {out, status} = swiftc(["-o", binary, kiln, Path.join([@fixtures, "swift", "main.swift"])])
    assert status == 0, "the generated file did not compile:\n#{out}"

    {output, status} = System.cmd(binary, [artifact], stderr_to_stdout: true)
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
      email: "swift-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp swiftc(args), do: System.cmd("swiftc", args, stderr_to_stdout: true)

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
end
