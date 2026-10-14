defmodule Kiln.ContractTest do
  @moduledoc """
  The contract compiles and behaves on its own, with no KilnCMS core loaded
  (#1909). The core's suite tests these modules in depth against its real
  blocks; this suite is what proves the package stands alone.
  """
  use ExUnit.Case, async: true

  alias Kiln.ContractTest.{Backend, Links, Note, Plugin, Stars}

  test "use Kiln.Plugin defaults every callback a plugin doesn't override" do
    assert Plugin.name() == "contract_test"
    assert Plugin.blocks() == [Note]
    assert Plugin.field_types() == []
  end

  test "use Kiln.Block builds an embedded resource from the DSL" do
    assert Kiln.Block.Info.name(Note) == :sdk_note
    assert Kiln.Block.Info.version(Note) == 2
    assert Enum.map(Kiln.Block.Info.fields(Note), & &1.name) == [:text, :tone]
    assert [%Kiln.Block.Migration{from: 1, to: 2}] = Kiln.Block.Info.migrations(Note)

    assert {:ok, note} = Ash.Type.cast_input(Note, %{text: "hi"}, [])
    assert note.tone == "info"
    assert note._type == "sdk_note"
    assert Note.render(note, :json) == %{"_type" => "sdk_note", "text" => "hi"}
    assert Note.search_text(note) == ""
  end

  test "field-level policy reads the block's own declarations" do
    assert Kiln.Block.Policy.editable_fields(Note, :editor) == [:text]
    assert Kiln.Block.Policy.authorize_changes(Note, :editor, [:tone]) == {:error, [:tone]}
    assert Kiln.Block.Policy.authorize_changes(Note, :admin, [:tone]) == :ok
  end

  test "a block describes itself as JSON Schema" do
    schema = Kiln.Block.JsonSchema.for_module(Note)
    assert schema["properties"]["_type"]["const"] == "sdk_note"
    assert "text" in schema["required"]
  end

  test "use Kiln.FieldType derives a name and label" do
    assert Stars.name() == :stars
    assert Stars.label() == "Stars"
    assert Stars.input_type() == "text"
    assert Stars.cast(3, nil) == {:ok, 3}
  end

  test "a spam check judges a context and flags with a weight" do
    assert Links.check(Kiln.Forms.SpamCheck.Context.new(%{"body" => "see http://x"})) ==
             {:flag, :link, 10}

    assert Links.check(Kiln.Forms.SpamCheck.Context.new(%{"body" => "hello"})) == :ok
  end

  test "use Kiln.ImageBackend defaults the optional callbacks" do
    assert Backend.render_url("k", %{}) == :unsupported
    assert Backend.csp_hosts() == []
    assert Backend.key_for_url("https://img.example/k") == :error
    assert Backend.check() == :unsupported
  end
end
