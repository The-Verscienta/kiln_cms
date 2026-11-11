defmodule Kiln.ContractTest do
  @moduledoc """
  The contract compiles and behaves on its own, with no KilnCMS core loaded
  (#1909). The core's suite tests these modules in depth against its real
  blocks; this suite is what proves the package stands alone.
  """
  use ExUnit.Case, async: true

  alias Kiln.ContractTest.{Backend, Captcha, Links, Note, Plugin, Stars}

  test "use Kiln.Plugin defaults every callback a plugin doesn't override" do
    assert Plugin.name() == "contract_test"
    assert Plugin.blocks() == [Note]
    assert Plugin.field_types() == []
    assert Plugin.plug_routes() == []
    assert Plugin.challenge_providers() == []
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

  describe "a challenge provider" do
    test "use Kiln.Challenge.Provider defaults the label, and a valid one conforms" do
      assert Captcha.label() == "Captcha"
      assert Kiln.Challenge.Provider.conformance(Captcha) == :ok

      assert {:ok, %{id: "sdk_captcha", widget: widget, csp_sources: csp}} =
               Kiln.Challenge.Provider.describe(Captcha)

      assert widget == %{
               script_url: "https://captcha.example/v1/api.js?render=explicit",
               global: "sdkCaptcha",
               api: :explicit_render,
               render_options: %{},
               action_option: nil,
               onload_param: nil,
               response_field: nil,
               interactive: false
             }

      assert csp.script_src == ["https://captcha.example/v1/"]
    end

    test "a module that is not a provider is named, not crashed on" do
      assert {:error, [problem]} = Kiln.Challenge.Provider.conformance(Plugin)
      assert problem =~ "does not implement Kiln.Challenge.Provider"
      assert {:error, [_]} = Kiln.Challenge.Provider.conformance(Kiln.ContractTest.NoSuchModule)
    end

    for {name, overrides, expected} <- [
          {"an id with capitals", [id: "MyCaptcha"], "id/0 must be a lowercase letter"},
          {"an id too long", [id: String.duplicate("a", 33)], "id/0 must be"},
          {"an http script", [script_url: "http://captcha.example/v1/api.js"],
           "must be an https:// URL"},
          {"a script with credentials", [script_url: "https://u:p@captcha.example/v1/api.js"],
           "must not carry credentials"},
          {"a script with a fragment", [script_url: "https://captcha.example/v1/api.js#x"],
           "must not carry a fragment"},
          {"a script with whitespace", [script_url: "https://captcha.example/v1/a pi.js"],
           "must not contain whitespace"},
          {"a script outside script_src", [script_url: "https://other.example/v1/api.js"],
           "is not covered by any csp_sources/0 script_src entry"},
          {"a script outside the source path", [script_url: "https://captcha.example/v2/api.js"],
           "is not covered"},
          {"a script on another port", [script_url: "https://captcha.example:8443/v1/api.js"],
           "is not covered"},
          {"a wildcard source", [script_src: ["https://*.captcha.example"]],
           "must be https://host[:port][/path]"},
          {"a keyword source", [frame_src: ["'unsafe-inline'"]], "must be https://host"},
          {"a source with a semicolon", [connect_src: ["https://a.example; script-src *"]],
           "must be https://host"},
          {"a source with a comma", [connect_src: ["https://a.example,https://b.example"]],
           "must be https://host"},
          {"a bare star", [frame_src: ["*"]], "must be https://host"},
          {"an http source", [frame_src: ["http://captcha.example"]], "must be https://host"},
          {"a global that is not an identifier", [global: "my-captcha"],
           "global \"my-captcha\" is not a valid name"},
          {"another api", [api: :invisible], "api must be :explicit_render"},
          {"a reserved render option", [render_options: %{"sitekey" => "x"}],
           "must not set \"sitekey\""},
          {"a callback render option", [render_options: %{"callback" => "x"}],
           "must not set \"callback\""},
          {"non-JSON render options", [render_options: %{theme: :dark}], "JSON-safe"},
          {"a non-boolean interactive", [interactive: "yes"], "interactive must be a boolean"},
          {"an onload param that is not a name", [onload_param: "on load"],
           "onload_param \"on load\" is not a valid name"}
        ] do
      test "refuses #{name}" do
        assert {:error, problems} =
                 Kiln.Challenge.Provider.conformance(
                   Kiln.ContractTest.ConfigurableCaptcha.with(unquote(Macro.escape(overrides)))
                 )

        assert Enum.any?(problems, &(&1 =~ unquote(expected))), inspect(problems)
      end
    end

    test "a raising callback is a problem" do
      module = Kiln.ContractTest.ConfigurableCaptcha.with(raise: :widget)
      assert {:error, problems} = Kiln.Challenge.Provider.conformance(module)
      assert Enum.any?(problems, &(&1 =~ "widget/0 raised"))
    end
  end
end
