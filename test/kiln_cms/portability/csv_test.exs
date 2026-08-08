defmodule KilnCMS.Portability.CSVTest do
  @moduledoc """
  CSV export/import for flat dynamic types (#949).

  Two things carry the weight here: the round trip has to survive a spreadsheet
  (quotes, commas, newlines, and the formula-injection guard), and the format
  has to *refuse* the cases where its lossiness would be silent.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Portability.CSV
  alias KilnCMS.Portability.Export
  alias KilnCMS.Portability.Import
  alias KilnCMSWeb.CSV, as: Codec

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "csv-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: "csvorg",
      slug: "csvorg-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  setup do
    actor = user(:admin)
    org = org()
    name = "listing#{System.unique_integer([:positive])}"

    definition =
      CMS.create_type_definition!(%{name: name, label: "Listing"}, actor: actor, tenant: org)

    for {field, type, position} <- [{"city", :string, 0}, {"seats", :integer, 1}] do
      CMS.create_field_definition!(
        %{
          type_definition_id: definition.id,
          name: field,
          label: String.capitalize(field),
          field_type: type,
          position: position
        },
        actor: actor,
        tenant: org
      )
    end

    %{actor: actor, org: org, name: name, scope: [actor: actor, tenant: org]}
  end

  defp create!(ctx, attrs) do
    ContentTypes.create!(
      ctx.name,
      Map.merge(%{blocks: [], slug: "l-#{System.unique_integer([:positive])}"}, attrs),
      ctx.scope
    )
  end

  defp export_csv(ctx) do
    {:ok, envelope} = Export.run([ctx.name], ctx.scope)
    CSV.encode(envelope["records"], ctx.name, ctx.scope)
  end

  describe "encode" do
    test "header is the fixed columns then the type's fields in declared order", ctx do
      create!(ctx, %{title: "A", custom_fields: %{"city" => "Leeds", "seats" => "4"}})

      {:ok, csv} = export_csv(ctx)
      [header | _] = Codec.parse(csv)

      assert header == ["title", "slug", "locale", "state", "city", "seats"]
    end

    test "writes one row per record", ctx do
      create!(ctx, %{title: "A", custom_fields: %{"city" => "Leeds"}})
      create!(ctx, %{title: "B", custom_fields: %{"city" => "Hull"}})

      {:ok, csv} = export_csv(ctx)
      assert length(Codec.parse(csv)) == 3
    end

    # The whole point of CSV here is a spreadsheet round trip, and a spreadsheet
    # is exactly where a comma or a newline in a cell breaks a naive writer.
    test "a value with commas, quotes and newlines survives", ctx do
      nasty = ~s(Leeds, "West" Yorkshire\nUK)
      create!(ctx, %{title: "Awkward", custom_fields: %{"city" => nasty}})

      {:ok, csv} = export_csv(ctx)
      {:ok, [record]} = CSV.decode(csv, ctx.name, ctx.scope)

      assert record["custom_fields"]["city"] == nasty
    end

    # `KilnCMSWeb.CSV` prefixes `'` so a spreadsheet cannot execute the cell.
    # The reader must undo exactly that, or a round trip grows a quote a cycle.
    test "a formula-looking value round-trips unchanged", ctx do
      create!(ctx, %{title: "Formula", custom_fields: %{"city" => "=SUM(A1:A9)"}})

      {:ok, csv} = export_csv(ctx)
      assert csv =~ "'=SUM"

      {:ok, [record]} = CSV.decode(csv, ctx.name, ctx.scope)
      assert record["custom_fields"]["city"] == "=SUM(A1:A9)"
    end

    test "a genuine leading apostrophe is not eaten", ctx do
      create!(ctx, %{title: "Apostrophe", custom_fields: %{"city" => "'tis Leeds"}})

      {:ok, csv} = export_csv(ctx)
      {:ok, [record]} = CSV.decode(csv, ctx.name, ctx.scope)

      assert record["custom_fields"]["city"] == "'tis Leeds"
    end

    # Refusing beats flattening: rendering prose to a cell loses the structure,
    # and re-importing that file would silently delete the author's formatting.
    test "a record carrying prose blocks is refused, naming the slugs", ctx do
      record =
        create!(ctx, %{title: "Has prose", blocks: [%{"_type" => "heading", "text" => "Hi"}]})

      assert {:error, {:has_blocks, slugs}} = export_csv(ctx)
      assert record.slug in slugs
    end
  end

  describe "decode" do
    test "empty input is refused rather than importing nothing quietly", ctx do
      assert {:error, :empty} = CSV.decode("", ctx.name, ctx.scope)
    end

    # A header typo would otherwise import every row with that field silently
    # empty — the likeliest spreadsheet mistake and the hardest to notice later.
    test "an unknown column is named, not dropped", ctx do
      csv = "title,slug,city,Seats\r\nA,a,Leeds,4\r\n"

      assert {:error, {:unknown_columns, ["Seats"]}} = CSV.decode(csv, ctx.name, ctx.scope)
    end

    test "state defaults to draft when the column is absent or blank", ctx do
      csv = "title,slug,city\r\nA,a,Leeds\r\n"
      {:ok, [record]} = CSV.decode(csv, ctx.name, ctx.scope)

      assert record["state"] == "draft"
    end

    test "a blank cell is omitted rather than written as an empty value", ctx do
      csv = "title,slug,city,seats\r\nA,a,,4\r\n"
      {:ok, [record]} = CSV.decode(csv, ctx.name, ctx.scope)

      refute Map.has_key?(record["custom_fields"], "city")
      assert record["custom_fields"]["seats"] == "4"
    end
  end

  describe "round trip through the real write path" do
    test "export, purge, import restores the records", ctx do
      a =
        create!(ctx, %{title: "Leeds site", custom_fields: %{"city" => "Leeds", "seats" => "40"}})

      b = create!(ctx, %{title: "Hull site", custom_fields: %{"city" => "Hull", "seats" => "12"}})

      {:ok, csv} = export_csv(ctx)

      for record <- [a, b], do: ContentTypes.purge(ctx.name, record, ctx.scope)

      {:ok, records} = CSV.decode(csv, ctx.name, ctx.scope)

      {:ok, report} =
        Import.run_envelope(%{"records" => records}, ctx.scope ++ [skip_media: true])

      assert report.failed == []
      assert length(report.created) == 2

      reloaded = ContentTypes.list!(ctx.name, ctx.scope)
      leeds = Enum.find(reloaded, &(&1.slug == a.slug))

      assert leeds.title == "Leeds site"
      assert leeds.custom_fields["city"] == "Leeds"
      assert leeds.custom_fields["seats"] == 40
    end

    test "re-importing the same file skips rather than duplicating", ctx do
      create!(ctx, %{title: "Leeds site", custom_fields: %{"city" => "Leeds"}})

      {:ok, csv} = export_csv(ctx)
      {:ok, records} = CSV.decode(csv, ctx.name, ctx.scope)

      {:ok, report} =
        Import.run_envelope(%{"records" => records}, ctx.scope ++ [skip_media: true])

      assert report.created == []
      assert length(report.skipped) == 1
    end
  end

  describe "KilnCMSWeb.CSV.parse/1" do
    test "quoted fields may contain commas, doubled quotes and newlines" do
      assert Codec.parse(~s(a,"b,c","d""e","f\ng"\r\n)) == [["a", "b,c", ~s(d"e), "f\ng"]]
    end

    test "bare newlines are accepted as row separators" do
      assert Codec.parse("a,b\nc,d\n") == [["a", "b"], ["c", "d"]]
    end

    # Excel and Google Sheets both write a UTF-8 BOM. Without stripping it the
    # first header cell is "\uFEFFtitle", which the importer then rejects as an
    # unknown column — breaking the one workflow this format exists for.
    test "a UTF-8 BOM from a spreadsheet is stripped" do
      assert Codec.parse("\uFEFFtitle,slug\r\nA,a\r\n") == [["title", "slug"], ["A", "a"]]
    end

    test "a spreadsheet-saved export still imports", ctx do
      create!(ctx, %{title: "Leeds site", custom_fields: %{"city" => "Leeds"}})
      {:ok, csv} = export_csv(ctx)

      assert {:ok, [record]} = CSV.decode("\uFEFF" <> csv, ctx.name, ctx.scope)
      assert record["title"] == "Leeds site"
    end

    # A truncated download or half-written file. Importing the surviving prefix
    # is worse than refusing it.
    test "an unterminated quoted field is refused, not silently truncated" do
      assert_raise ArgumentError, ~r/never closed/, fn ->
        Codec.parse(~s(a,"unterminated\r\nb,c\r\n))
      end
    end

    test "is the inverse of line/1 for awkward values" do
      row = ["plain", "with,comma", ~s(with "quote"), "with\nnewline", "=formula", "'tis"]

      assert Codec.parse(Codec.line(row)) == [row]
    end
  end
end
