defmodule Kiln.ContractTest do
  @moduledoc """
  The contract compiles and behaves on its own, with no KilnCMS core loaded
  (#1909). The core's suite tests these modules in depth against its real
  blocks; this suite is what proves the package stands alone.
  """
  use ExUnit.Case, async: true

  alias Kiln.ContractTest.{Backend, Captcha, Destination, Links, Note, Plugin, Stars}

  test "use Kiln.Plugin defaults every callback a plugin doesn't override" do
    assert Plugin.name() == "contract_test"
    assert Plugin.blocks() == [Note]
    assert Plugin.field_types() == []
    assert Plugin.plug_routes() == []
    assert Plugin.challenge_providers() == []
    assert Plugin.backup_destinations() == []
    assert Plugin.staging_scrub() == []
  end

  test "staging_scrub/0 is part of the plugin contract, defaulted by use Kiln.Plugin" do
    assert {:staging_scrub, 0} in Kiln.Plugin.behaviour_info(:callbacks)
    refute {:staging_scrub, 0} in Kiln.Plugin.behaviour_info(:optional_callbacks)
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

  describe "a backup destination" do
    test "the contract's callbacks and arities, with supports/0 and abort_upload/3 optional" do
      assert Enum.sort(Kiln.BackupDestination.behaviour_info(:callbacks)) == [
               abort_upload: 3,
               delete: 2,
               describe: 1,
               fields: 0,
               get: 3,
               kind: 0,
               label: 0,
               list: 1,
               put: 3,
               supports: 0,
               test: 1,
               validate: 1
             ]

      assert Enum.sort(Kiln.BackupDestination.behaviour_info(:optional_callbacks)) == [
               abort_upload: 3,
               supports: 0
             ]
    end

    test "use Kiln.BackupDestination defines no abort_upload/3, so nothing resumes by default" do
      refute function_exported?(Destination, :abort_upload, 3)
    end

    test "a resume's inspect shows only its attempt, never its checkpoint or save" do
      resume = %Kiln.BackupDestination.Resume{
        checkpoint: %{"upload_id" => "upload-id-xyz"},
        attempt: 2,
        save: fn _checkpoint -> :ok end
      }

      inspected = inspect(resume)
      assert inspected =~ "attempt: 2"
      refute inspected =~ "upload-id-xyz"
      refute inspected =~ "save"
      assert resume.save.(%{"part" => 1}) == :ok
    end

    test "a resume needs a save, and defaults to a fresh start on attempt 1" do
      assert %Kiln.BackupDestination.Resume{checkpoint: nil, attempt: 1} =
               struct!(Kiln.BackupDestination.Resume, save: fn _ -> :ok end)

      assert_raise ArgumentError, fn -> struct!(Kiln.BackupDestination.Resume, []) end
    end

    test "use Kiln.BackupDestination defaults supports/0 to nothing, so nothing is pruned" do
      assert Destination.supports() == []
      assert Kiln.BackupDestination in Keyword.get(Destination.__info__(:attributes), :behaviour)
    end

    test "a config's inspect shows neither its settings nor its secrets" do
      config = %Kiln.BackupDestination.Config{
        id: "0b6f8d1e-6a47-4c7e-9a0e-3c1b2d4e5f60",
        key: "dest:0b6f8d1e-6a47-4c7e-9a0e-3c1b2d4e5f60",
        kind: "sdk_test",
        settings: %{"bucket" => "private-bucket-name"},
        secrets: %{"token" => "s3cr3t-xyz"}
      }

      inspected = inspect(config)
      assert inspected =~ "sdk_test"
      assert inspected =~ "dest:0b6f8d1e"
      refute inspected =~ "s3cr3t-xyz"
      refute inspected =~ "private-bucket-name"
      refute inspected =~ "secrets"

      # Nested in a crash-report-shaped term too.
      refute inspect({:put, [config, %{name: "x"}]}, limit: :infinity) =~ "s3cr3t-xyz"

      assert Destination.describe(config) == "sdk-test:0b6f8d1e-6a47-4c7e-9a0e-3c1b2d4e5f60"
    end

    test "a config needs a kind, and defaults to empty settings and secrets" do
      assert %Kiln.BackupDestination.Config{settings: %{}, secrets: %{}, id: nil} =
               struct!(Kiln.BackupDestination.Config, kind: "sdk_test")

      assert_raise ArgumentError, fn -> struct!(Kiln.BackupDestination.Config, []) end
    end
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
