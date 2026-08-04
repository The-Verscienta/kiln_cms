defmodule KilnCMS.Forms.AutoresponderTest do
  @moduledoc """
  The submitter confirmation email (#468): eligibility, token rendering, and
  the escaped-subject-vs-plain-body split. End-to-end wiring through
  `KilnCMS.Forms.submit/3` is covered in `KilnCMS.FormsTest`.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.FormField
  alias KilnCMS.Forms.Autoresponder

  defp email_field(name \\ "email"), do: %FormField{name: name, field_type: :email}
  defp text_field(name), do: %FormField{name: name, field_type: :string}

  describe "eligible?/3" do
    test "false when the autoresponder is off, regardless of fields/data" do
      form = %{autoresponder_enabled: false}
      refute Autoresponder.eligible?(form, %{"email" => "a@b.com"}, [email_field()])
    end

    test "false when the form declares no email field" do
      form = %{autoresponder_enabled: true}
      refute Autoresponder.eligible?(form, %{"message" => "hi"}, [text_field("message")])
    end

    test "false when the email field was left blank" do
      form = %{autoresponder_enabled: true}
      refute Autoresponder.eligible?(form, %{"email" => ""}, [email_field()])
      refute Autoresponder.eligible?(form, %{}, [email_field()])
    end

    test "true with the submitted address when everything lines up" do
      form = %{autoresponder_enabled: true}

      assert {true, "visitor@example.com"} =
               Autoresponder.eligible?(form, %{"email" => "visitor@example.com"}, [
                 text_field("message"),
                 email_field()
               ])
    end
  end

  describe "definitions/3" do
    test "one [field:<name>] token per field, plus [form-name]" do
      defs = Autoresponder.definitions([text_field("message")], "Contact", false)
      names = Enum.map(defs, & &1.match)
      assert "field:message" in names
      assert "form-name" in names
    end

    test "escape?: false resolves raw values" do
      [name_def] =
        Enum.filter(Autoresponder.definitions([], "A & B", false), &(&1.match == "form-name"))

      assert name_def.resolve.("form-name", %{}) == "A & B"
    end

    test "escape?: true HTML-escapes resolved values" do
      [name_def] =
        Enum.filter(Autoresponder.definitions([], "A & B", true), &(&1.match == "form-name"))

      assert name_def.resolve.("form-name", %{}) == "A &amp; B"
    end
  end

  describe "render/3" do
    test "expands the subject unescaped and the body escaped" do
      form = %{
        name: "Contact <Us>",
        autoresponder_subject: "Thanks, [field:name]!",
        autoresponder_body: "<p>Hi [field:name], from [form-name].</p>"
      }

      fields = [text_field("name")]
      data = %{"name" => "Ada <script>"}

      {subject, body} = Autoresponder.render(form, fields, data)

      assert subject == "Thanks, Ada <script>!"
      assert body == "<p>Hi Ada &lt;script&gt;, from Contact &lt;Us&gt;.</p>"
    end
  end
end
