defmodule KilnCMSWeb.PublicFormGoldenTest do
  @moduledoc """
  A form with no conditions renders exactly as it did before conditional
  fields existed (#2262): every field type, a first render and a refused
  re-render, byte for byte against markup recorded from the release before.
  Only a form with a condition gets the new attributes and the script tag.

  The recorded markup is `test/support/fixtures/public_form_golden/*.html`.
  A deliberate change to the public form's markup re-records it with
  `KILN_RECORD_GOLDEN=1 mix test <this file>`; review the diff.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.CMS.Form
  alias KilnCMS.CMS.FormField
  alias KilnCMSWeb.BlockComponents

  @dir "test/support/fixtures/public_form_golden"

  defp field(type, name, attrs \\ []) do
    struct!(
      FormField,
      Keyword.merge(
        [
          name: name,
          label: "Label #{name}",
          field_type: type,
          required: false,
          options: [],
          help_text: nil,
          placeholder: nil,
          default_value: nil,
          width: :full,
          min_value: nil,
          max_value: nil,
          step: nil,
          position: 0
        ],
        attrs
      )
    )
  end

  defp form do
    %Form{
      slug: "golden",
      description: "Tell us about it",
      submit_label: nil,
      challenge: :off,
      fields: [
        field(:string, "name", required: true, placeholder: "Your name", width: :half),
        field(:email, "email", required: true, help_text: "We reply here", width: :half),
        field(:text, "message", default_value: "Hello"),
        field(:integer, "count", width: :third),
        field(:boolean, "agree", required: true),
        field(:date, "day"),
        field(:select, "topic", options: ["Sales", "Support"], required: true),
        field(:radio, "size", options: ["S", "M"], required: true),
        field(:checkboxes, "colours", options: ["Red", "Blue"], required: true),
        field(:phone, "phone"),
        field(:url, "site"),
        field(:hidden, "utm", default_value: "spring"),
        field(:number, "amount", min_value: 1.0, max_value: 10.0, step: 0.5),
        field(:rating, "stars", max_value: 3.0, required: true)
      ]
    }
  end

  defp render_form(assigns) do
    render_component(&BlockComponents.public_form/1, Keyword.put(assigns, :rendered_at, "tok"))
  end

  defp assert_golden(name, html) do
    path = Path.join(@dir, name <> ".html")

    if System.get_env("KILN_RECORD_GOLDEN") == "1" do
      File.mkdir_p!(@dir)
      File.write!(path, html)
    end

    assert html == File.read!(path), "the public form's markup changed: #{path}"
  end

  test "a first render of a form with no conditions is unchanged" do
    assert_golden("first_render", render_form(form: form()))
  end

  test "a refused re-render of a form with no conditions is unchanged" do
    html =
      render_form(
        form: form(),
        values: %{"name" => "Ada", "colours" => ["Blue"], "stars" => "2"},
        errors: %{"email" => "is required", "topic" => "is not one of the allowed options"},
        variant: "b",
        embed: true,
        action: "/fr/forms/golden"
      )

    assert_golden("refused_render", html)
  end
end
