defmodule KilnCMS.CMS.FieldKindTest do
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.FieldKind
  alias KilnCMS.CMS.FieldTypes

  defp definition(type, extra \\ %{}), do: Map.merge(%{field_type: type, multiple: false}, extra)

  # A hand-rolled plugin type that predates `graphql_kind/1`: no callback.
  defmodule NoCallback do
    @behaviour Kiln.FieldType
    @impl true
    def name, do: :no_callback
    @impl true
    def label, do: "No callback"
    @impl true
    def input_type, do: "text"
    @impl true
    def input_attrs(_definition), do: %{}
    @impl true
    def cast(value, _definition), do: {:ok, value}
  end

  defmodule Scalar do
    use Kiln.FieldType
    @impl true
    def cast(value, _definition), do: {:ok, value}
    @impl true
    def graphql_kind(_definition), do: :int
  end

  defmodule Bogus do
    use Kiln.FieldType
    @impl true
    def cast(value, _definition), do: {:ok, value}
    @impl true
    def graphql_kind(_definition), do: :banana
  end

  test "every registered field type has a kind" do
    # A new core, built-in or plugin type that `kind_for/1` cannot place raises
    # or returns a non-kind here, so the registry cannot grow a silent gap.
    kinds = [
      :string,
      :int,
      :float,
      :boolean,
      :date,
      :datetime,
      :group,
      :reference,
      :media,
      :geolocation,
      :json
    ]

    for name <- FieldTypes.names() do
      assert FieldKind.kind_for(definition(name)) in kinds,
             "field type #{inspect(name)} has no GraphQL kind"
    end
  end

  test "every core type maps explicitly, not by the :json fallback" do
    expected = %{
      string: :string,
      text: :string,
      url: :string,
      select: :string,
      user: :string,
      integer: :int,
      float: :float,
      boolean: :boolean,
      date: :date,
      datetime: :datetime,
      media: :media,
      reference: :reference,
      group: :group
    }

    assert Enum.sort(FieldTypes.core()) == Enum.sort(Map.keys(expected))

    for {type, kind} <- expected, do: assert(FieldKind.kind_for(definition(type)) == kind)
  end

  test "the other built-in Kiln.FieldType modules answer :json" do
    for type <- [:computed, :datetime_range, :recurrence, :range, :key_value, :link] do
      assert FieldKind.kind_for(definition(type)) == :json
    end
  end

  test "geolocation is mapped by the core, not by a plugin callback" do
    assert FieldKind.kind_for(definition(:geolocation)) == :geolocation
    assert FieldKind.kind_for(definition(:geolocation, %{multiple: true})) == :list
    assert FieldKind.item_kind_for(definition(:geolocation, %{multiple: true})) == :geolocation
    refute :geolocation in FieldTypes.core()
    refute function_exported?(KilnCMS.CMS.FieldTypes.Geolocation, :graphql_kind, 1)
  end

  test "the fixture plugin's rating type, which has no graphql_kind/1, is :json" do
    assert :rating in FieldTypes.names()
    refute function_exported?(KilnCMS.FixturePlugin.FieldTypes.Rating, :graphql_kind, 1)
    assert FieldKind.kind_for(definition(:rating)) == :json
  end

  test "multiple is a list whatever the item type, and item_kind_for/1 sees through it" do
    for type <- [:string, :integer, :media, :reference, :group, :select, :rating] do
      multiple = definition(type, %{multiple: true})
      assert FieldKind.kind_for(multiple) == :list
      assert FieldKind.item_kind_for(multiple) == FieldKind.kind_for(definition(type))
    end
  end

  test "a definition without a multiple key is a single value" do
    assert FieldKind.kind_for(%{field_type: :float}) == :float
  end

  describe "the optional graphql_kind/1 callback" do
    test "is honoured when the module implements it" do
      assert FieldKind.kind_from_module(Scalar, definition(:scalar)) == :int
    end

    test "defaults to :json when the module predates it" do
      refute function_exported?(NoCallback, :graphql_kind, 1)
      assert FieldKind.kind_from_module(NoCallback, definition(:no_callback)) == :json
    end

    test "falls back to :json for an answer that is not a scalar kind" do
      assert FieldKind.kind_from_module(Bogus, definition(:bogus)) == :json
    end

    test "falls back to :json for an unregistered type" do
      assert FieldKind.kind_for(definition(:not_registered)) == :json
    end
  end
end
