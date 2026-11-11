defmodule KilnCMS.CMS.FieldWidgetsTest do
  @moduledoc """
  `KilnCMS.CMS.FieldWidgets` (#2284): which editor inputs a field's settings
  offer, which it uses, and which the editor renders. Pure — the definition
  rules that store a widget are in `KilnCMS.CMS.FieldWidgetDefinitionTest`.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldWidgets

  defp field(attrs), do: struct(FieldDefinition, Map.merge(%{field_type: :string}, attrs))

  describe "allowed/1 and default/1" do
    test "a single select: dropdown, radios, buttons" do
      select = field(%{field_type: :select, options: ~w(a b)})

      assert FieldWidgets.allowed(select) == ~w(dropdown radios buttons)
      assert FieldWidgets.default(select) == "dropdown"
    end

    test "a multiple select: tags, checkboxes" do
      select = field(%{field_type: :select, multiple: true, options: ~w(a b)})

      assert FieldWidgets.allowed(select) == ~w(tags checkboxes)
      assert FieldWidgets.default(select) == "tags"
    end

    test "an open vocabulary has no checkboxes" do
      select = field(%{field_type: :select, multiple: true, allow_custom: true})

      assert FieldWidgets.allowed(select) == ~w(tags)
    end

    test "plain text: textarea, single_line" do
      text = field(%{field_type: :text, format: :plain})

      assert FieldWidgets.allowed(text) == ~w(textarea single_line)
      assert FieldWidgets.default(text) == "textarea"
    end

    test "rich text has no choice" do
      assert FieldWidgets.allowed(field(%{field_type: :text, format: :rich})) == []
      assert FieldWidgets.default(field(%{field_type: :text, format: :rich})) == nil
    end

    test "a text field with no format reads as rich, its default" do
      assert FieldWidgets.allowed(%{field_type: :text}) == []
    end

    test "a single reference: autocomplete, dropdown" do
      reference = field(%{field_type: :reference, target_type: "page"})

      assert FieldWidgets.allowed(reference) == ~w(autocomplete dropdown)
      assert FieldWidgets.default(reference) == "autocomplete"
    end

    test "a multiple reference has no choice" do
      assert FieldWidgets.allowed(field(%{field_type: :reference, multiple: true})) == []
    end

    test "a link field and a group sub-field have no choice, whatever their type" do
      parent = Ecto.UUID.generate()

      for owner <- [:link_of_id, :group_of_id] do
        select = field(%{:field_type => :select, :options => ~w(a b), owner => parent})
        text = field(%{:field_type => :text, :format => :plain, owner => parent})

        assert FieldWidgets.allowed(select) == []
        assert FieldWidgets.allowed(text) == []
      end
    end

    test "every other core type has no choice" do
      for type <- [:string, :integer, :float, :boolean, :date, :datetime, :url, :media, :group] do
        assert FieldWidgets.allowed(field(%{field_type: type})) == [], "#{type}"
      end
    end

    test "a built-in type without widgets/1 has no choice" do
      assert FieldWidgets.allowed(field(%{field_type: :geolocation})) == []
    end

    test "a plugin type offers what its widgets/1 declares, default first" do
      rating = field(%{field_type: :rating})

      assert FieldWidgets.allowed(rating) == ~w(number stars)
      assert FieldWidgets.default(rating) == "number"
    end

    test "a plugin type without widgets/1 has no choice" do
      assert FieldWidgets.allowed(field(%{field_type: :tokenless})) == []
    end

    test "an unknown type has no choice" do
      assert FieldWidgets.allowed(field(%{field_type: :no_such_type})) == []
      assert FieldWidgets.allowed(%{}) == []
    end
  end

  describe "resolve/1" do
    test "answers the stored widget while the field offers it" do
      assert FieldWidgets.resolve(field(%{field_type: :select, widget: "radios"})) == "radios"
      assert FieldWidgets.resolve(field(%{field_type: :rating, widget: "stars"})) == "stars"
    end

    test "answers the default when none is stored, or an ad-hoc map has no widget key" do
      assert FieldWidgets.resolve(field(%{field_type: :select})) == "dropdown"
      assert FieldWidgets.resolve(%{field_type: :select, options: ~w(a)}) == "dropdown"
    end

    test "answers the default for a stored widget the field no longer offers" do
      assert FieldWidgets.resolve(field(%{field_type: :select, multiple: true, widget: "radios"})) ==
               "tags"

      assert FieldWidgets.resolve(field(%{field_type: :rating, widget: "dropped"})) == "number"
    end

    test "is nil for a field with no choice" do
      assert FieldWidgets.resolve(field(%{field_type: :string, widget: "radios"})) == nil
    end
  end

  describe "effective/1" do
    defp options(n), do: Enum.map(1..n, &"o#{&1}")

    test "is resolve/1 up to the option cap" do
      cap = FieldWidgets.option_cap()
      select = field(%{field_type: :select, options: options(cap), widget: "radios"})

      assert cap == 50
      assert FieldWidgets.effective(select) == "radios"
    end

    test "falls back to the default for a per-option widget past the cap" do
      many = options(FieldWidgets.option_cap() + 1)

      assert FieldWidgets.effective(
               field(%{field_type: :select, options: many, widget: "radios"})
             ) ==
               "dropdown"

      assert FieldWidgets.effective(
               field(%{field_type: :select, options: many, widget: "buttons"})
             ) ==
               "dropdown"

      assert FieldWidgets.effective(
               field(%{field_type: :select, multiple: true, options: many, widget: "checkboxes"})
             ) == "tags"
    end

    test "leaves a widget that isn't per-option alone past the cap" do
      many = options(FieldWidgets.option_cap() + 1)

      assert FieldWidgets.effective(field(%{field_type: :select, options: many})) == "dropdown"
      assert FieldWidgets.per_option?("radios")
      refute FieldWidgets.per_option?("dropdown")
    end
  end

  describe "plugin_labels/1" do
    test "names a plugin type's labelled widgets only" do
      assert FieldWidgets.plugin_labels(field(%{field_type: :rating})) == %{"stars" => "Stars"}
    end

    test "is empty for a core type" do
      assert FieldWidgets.plugin_labels(field(%{field_type: :select})) == %{}
    end
  end

  describe "a plugin's widget list" do
    defmodule Messy do
      def widgets(_definition),
        do: [:ok_one, {:labelled, "Labelled"}, :ok_one, "string", {:bad, :label}, :Bad, nil, 3]
    end

    defmodule NotAList do
      def widgets(_definition), do: :stars
    end

    defmodule Raising do
      def widgets(_definition), do: raise("widgets blew up")
    end

    defmodule PerDefinition do
      def widgets(%{multiple: true}), do: [:list]
      def widgets(_definition), do: [:one]
    end

    test "keeps well-formed entries once, in order, and drops the rest" do
      assert FieldWidgets.plugin_widgets(Messy, %{}) == [
               {"ok_one", nil},
               {"labelled", "Labelled"}
             ]
    end

    test "offers nothing when it isn't a list, or raises" do
      assert FieldWidgets.plugin_widgets(NotAList, %{}) == []
      assert FieldWidgets.plugin_widgets(Raising, %{}) == []
    end

    test "is asked with the definition" do
      assert FieldWidgets.plugin_widgets(PerDefinition, %{multiple: true}) == [{"list", nil}]
      assert FieldWidgets.plugin_widgets(PerDefinition, %{multiple: false}) == [{"one", nil}]
    end
  end
end
