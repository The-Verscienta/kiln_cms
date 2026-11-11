defmodule KilnCMS.CMS.BuiltinFormatFieldsTest do
  @moduledoc """
  The built-in format field types (#2278): `:email`, `:telephone`, `:color`,
  `:slug`, `:time` and `:json`. Each registers through `Kiln.FieldType` like a
  plugin's, casts totally (an error tuple, never a raise), and round-trips
  through `ApplyCustomFields`, the delivery API and the filter surface.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldTypes
  alias KilnCMS.CMS.FieldTypes.{Color, Email, Json, Slug, Telephone, TimeField}

  @types [:email, :telephone, :color, :slug, :time, :json]

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fmt-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define!(actor, type, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :page,
          name: "#{type}_#{System.unique_integer([:positive])}",
          label: "A #{type}",
          field_type: type
        },
        attrs
      ),
      actor: actor
    )
  end

  defp page(actor, fields),
    do:
      CMS.create_page(
        %{
          title: "Fmt",
          slug: "fmt-#{System.unique_integer([:positive])}",
          custom_fields: fields
        },
        actor: actor
      )

  describe "registration" do
    test "every type is built in, reserved and described" do
      for type <- @types do
        assert module = FieldTypes.get(type)
        assert module in FieldTypes.builtin()
        assert type in FieldTypes.reserved()
        assert is_binary(module.description())
        assert module.name() == type
      end
    end

    test "the string types are GraphQL strings, json is json" do
      for type <- @types -- [:json],
          do: assert(KilnCMS.CMS.FieldKind.kind_for(%{field_type: type}) == :string)

      assert KilnCMS.CMS.FieldKind.kind_for(%{field_type: :json}) == :json
    end
  end

  describe "email" do
    test "lowercases the domain, keeps the local part, trims" do
      assert Email.cast("  Ada.L@Example.COM ", nil) == {:ok, "Ada.L@example.com"}
    end

    test "refuses what is not an address" do
      for bad <- [
            "plain",
            "a@b",
            "a@@b.co",
            "a b@example.com",
            "a@exa mple.com",
            "@example.com",
            "a@.example.com",
            "a@example..com",
            "a@-example.com",
            ".a@example.com",
            "a..b@example.com",
            "a\u0000@example.com",
            "a\u00A0b@example.com",
            "a\u2028b@example.com",
            "a\u200Bb@example.com",
            "ab@exam\u200Bple.com",
            "ab@example.com\u00A0x",
            String.duplicate("a", 65) <> "@example.com",
            "a@" <> String.duplicate("a", 250) <> ".com",
            <<0xFF, ?@, ?a, ?., ?b>>
          ] do
        assert {:error, _} = Email.cast(bad, nil), inspect(bad)
      end
    end

    test "is total over non-strings" do
      for bad <- [1, 1.5, nil, true, %{}, [], %{"a" => 1}, ~D[2026-01-01], {:a}] do
        assert {:error, _} = Email.cast(bad, nil)
      end
    end

    test "a long hostile string finishes quickly" do
      {micros, result} =
        :timer.tc(fn ->
          Email.cast(String.duplicate("a.", 120) <> "@" <> String.duplicate("a", 200), nil)
        end)

      assert {:error, _} = result
      assert micros < 500_000
    end
  end

  describe "telephone" do
    test "normalises to E.164" do
      assert Telephone.cast("+1 (555) 123-4567", nil) == {:ok, "+15551234567"}
      assert Telephone.cast("+44 20.7946.0958", nil) == {:ok, "+442079460958"}
      assert Telephone.cast("0044 20 7946 0958", nil) == {:ok, "+442079460958"}
    end

    test "refuses domestic numbers, extensions, letters and bad lengths" do
      for bad <- [
            "020 7946 0958",
            "+1 555 123 4567 x12",
            "+0 555 123 4567",
            "+12345",
            "+1234567890123456",
            "call me",
            "",
            "+1" <> String.duplicate("5", 80)
          ] do
        assert {:error, message} = Telephone.cast(bad, nil)
        assert message =~ "country code"
      end

      for bad <- [5_551_234_567, nil, %{}, []], do: assert({:error, _} = Telephone.cast(bad, nil))
    end
  end

  describe "color" do
    test "expands shorthand and lowercases" do
      assert Color.cast("#F80", nil) == {:ok, "#ff8800"}
      assert Color.cast(" #A1B2C3 ", nil) == {:ok, "#a1b2c3"}
    end

    test "refuses everything else" do
      for bad <- [
            "ff8800",
            "#ff88",
            "#ff88000",
            "#gg0000",
            "red",
            "rgb(1,2,3)",
            123,
            nil,
            %{}
          ],
          do: assert({:error, _} = Color.cast(bad, nil), inspect(bad))
    end
  end

  describe "slug" do
    test "slugifies, and is idempotent" do
      {:ok, once} = Slug.cast("Café Menu -- 2026!", nil)
      assert once == "cafe-menu-2026"
      assert Slug.cast(once, nil) == {:ok, once}
    end

    test "refuses an empty result, over-length and non-text" do
      for bad <- [
            "",
            "!!!",
            "北京",
            String.duplicate("a", 129),
            String.duplicate("x ", 5_000),
            <<0xFF>>,
            5,
            nil,
            %{}
          ],
          do: assert({:error, _} = Slug.cast(bad, nil), inspect(bad))
    end
  end

  describe "time" do
    test "pads, drops seconds" do
      assert TimeField.cast("9:05", nil) == {:ok, "09:05"}
      assert TimeField.cast("09:05:59", nil) == {:ok, "09:05"}
      assert TimeField.cast("00:00", nil) == {:ok, "00:00"}
      assert TimeField.cast("23:59", nil) == {:ok, "23:59"}
    end

    test "refuses out-of-range and malformed" do
      for bad <- [
            "24:00",
            "12:60",
            "12:30:60",
            "12",
            "12:3",
            "1:2:3",
            "noon",
            "12:30pm",
            "-1:00",
            1230,
            nil
          ],
          do: assert({:error, _} = TimeField.cast(bad, nil), inspect(bad))
    end

    test "string order is time order" do
      times = for t <- ["9:30", "17:00", "08:15", "00:05"], do: elem(TimeField.cast(t, nil), 1)
      assert Enum.sort(times) == ["00:05", "08:15", "09:30", "17:00"]
    end
  end

  describe "json" do
    test "decodes text and stores the structure" do
      assert Json.cast(~s({"a": [1, 2, {"b": null}]}), nil) ==
               {:ok, %{"a" => [1, 2, %{"b" => nil}]}}

      assert Json.cast("[1, 2]", nil) == {:ok, [1, 2]}
    end

    test "accepts decoded maps and lists, stringifying atom keys; empty ones are values" do
      assert Json.cast(%{a: 1}, nil) == {:ok, %{"a" => 1}}
      assert Json.cast(%{}, nil) == {:ok, %{}}
      assert Json.cast([], nil) == {:ok, []}
      assert Json.cast("{}", nil) == {:ok, %{}}
    end

    test "refuses scalars, bad JSON and non-JSON terms" do
      for bad <- [
            "3",
            ~s("x"),
            "true",
            "null",
            "{oops",
            <<0xFF>>,
            3,
            true,
            nil,
            ~D[2026-01-01],
            {:a},
            %{1 => 2},
            [self()],
            [1 | 2],
            %{"a" => {:b}}
          ] do
        assert {:error, _} = Json.cast(bad, nil), inspect(bad)
      end
    end

    test "a nesting bomb is refused, not crashed on" do
      depth = 40_000
      bomb = String.duplicate("[", depth) <> String.duplicate("]", depth)
      assert {:error, message} = Json.cast(bomb, nil)
      assert message =~ "nested"

      nested = Enum.reduce(1..40_000, [], fn _, acc -> [acc] end)
      assert {:error, _} = Json.cast(nested, nil)
    end

    test "a NUL in a string or key is refused on every path (jsonb cannot store it)" do
      for bad <- [
            ~s({"a": "x\\u0000y"}),
            ~s({"a\\u0000": 1}),
            ~s(["x\\u0000"]),
            %{"a" => "x\0y"},
            %{"a\0" => 1},
            ["x\0"],
            %{a: ["deep", %{"k" => "\0"}]}
          ] do
        assert {:error, "must be valid JSON"} = Json.cast(bad, nil), inspect(bad)
      end
    end

    test "size and node caps" do
      big = Jason.encode!(%{"k" => String.duplicate("x", 70_000)})
      assert {:error, message} = Json.cast(big, nil)
      assert message =~ "64 KB"

      wide = Jason.encode!(Enum.to_list(1..6_000))
      assert {:error, message} = Json.cast(wide, nil)
      assert message =~ "values"

      assert {:ok, _} = Json.cast(Jason.encode!(%{"k" => String.duplicate("x", 60_000)}), nil)
    end
  end

  describe "through ApplyCustomFields" do
    test "values are stored normalised and served as JSON" do
      actor = admin()
      defs = for type <- @types, into: %{}, do: {type, define!(actor, type)}

      input = %{
        defs.email.name => "Ann@Example.ORG",
        defs.telephone.name => "+44 20 7946 0958",
        defs.color.name => "#ABC",
        defs.slug.name => "Hello World",
        defs.time.name => "7:05",
        defs.json.name => ~s({"x": [1]})
      }

      assert {:ok, page} = page(actor, input)
      fields = page.custom_fields
      assert fields[defs.email.name] == "Ann@example.org"
      assert fields[defs.telephone.name] == "+442079460958"
      assert fields[defs.color.name] == "#aabbcc"
      assert fields[defs.slug.name] == "hello-world"
      assert fields[defs.time.name] == "07:05"
      assert fields[defs.json.name] == %{"x" => [1]}
      assert {:ok, _} = Jason.encode(fields)
    end

    test "an invalid value fails the write, naming the field" do
      actor = admin()
      email = define!(actor, :email)
      assert {:error, error} = page(actor, %{email.name => "nope"})
      assert Exception.message(error) =~ "email address"
    end

    test "required rejects blank; an empty json object is a value" do
      actor = admin()
      email = define!(actor, :email, %{required: true})
      json = define!(actor, :json, %{required: true})

      assert {:error, _} = page(actor, %{email.name => "", json.name => "{}"})
      assert {:ok, page} = page(actor, %{email.name => "a@b.co", json.name => %{}})
      assert page.custom_fields[json.name] == %{}
    end
  end

  describe "filter and sort" do
    test "email filters by equality and contains; time orders and compares" do
      actor = admin()
      email = define!(actor, :email)
      time = define!(actor, :time)

      {:ok, a} = page(actor, %{email.name => "a@example.com", time.name => "09:00"})
      {:ok, b} = page(actor, %{email.name => "b@other.org", time.name => "17:30"})

      ids = fn inputs -> inputs |> CMS.list_pages!(actor: actor) |> Enum.map(& &1.id) end

      assert ids.(%{custom_filter: %{email.name => "a@example.com"}}) == [a.id]
      assert ids.(%{custom_filter: %{email.name => %{"contains" => "other"}}}) == [b.id]
      assert ids.(%{custom_filter: %{time.name => %{"gt" => "12:00"}}}) == [b.id]

      sorted =
        ids.(%{custom_filter: %{time.name => %{"null" => false}}, custom_sort: "-" <> time.name})

      assert sorted == [b.id, a.id]
    end

    test "json answers null only, and cannot be sorted" do
      actor = admin()
      json = define!(actor, :json)
      {:ok, with_json} = page(actor, %{json.name => %{"a" => 1}})

      assert [%{id: id}] =
               CMS.list_pages!(%{custom_filter: %{json.name => %{"null" => false}}}, actor: actor)

      assert id == with_json.id

      for filter <- [%{"eq" => "x"}, %{"contains" => "a"}, %{"gt" => "1"}, "x"] do
        assert {:error, error} =
                 CMS.list_pages(%{custom_filter: %{json.name => filter}}, actor: actor)

        assert Exception.message(error) =~ "only supports null"
      end

      assert {:error, error} = CMS.list_pages(%{custom_sort: json.name}, actor: actor)
      assert Exception.message(error) =~ "not sortable"
    end
  end
end
