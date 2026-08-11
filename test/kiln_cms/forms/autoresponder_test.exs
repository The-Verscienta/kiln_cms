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

    test "with multiple email fields, the first (by the caller's own field order) wins" do
      # `eligible?/3` doesn't re-sort `fields` — it trusts the order the caller
      # already fetched them in (`Form.fields`'s `position, name` sort, or
      # `FormField.for_form`'s matching sort), so this only documents that
      # `Enum.find/2` picks the first match rather than, say, erroring or
      # picking a "primary" field some other way.
      form = %{autoresponder_enabled: true}

      assert {true, "first@example.com"} =
               Autoresponder.eligible?(
                 form,
                 %{"first" => "first@example.com", "second" => "second@example.com"},
                 [email_field("first"), email_field("second")]
               )
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

    test "a submitted field value can't smuggle a CR/LF into the subject header" do
      # The subject is a mail header, not HTML — HTML-escaping wouldn't touch
      # a raw newline anyway. A submitter putting "Ada\r\nBcc: evil@x.com" in
      # a field the template references must not reach Swoosh's subject/2
      # with the line break intact (header injection).
      form = %{
        name: "Contact",
        autoresponder_subject: "Thanks, [field:name]!",
        autoresponder_body: "b"
      }

      {subject, _body} =
        Autoresponder.render(form, [text_field("name")], %{
          "name" => "Ada\r\nBcc: evil@example.com"
        })

      refute subject =~ "\r"
      refute subject =~ "\n"
      assert subject == "Thanks, Ada Bcc: evil@example.com!"
    end
  end
end
