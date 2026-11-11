defmodule KilnCMSWeb.FormFieldTypesRenderTest do
  @moduledoc """
  The public renderer for the field types added in #2261: one accessible
  control per type, never the plain text input an unhandled type would fall
  back to, and an invalid re-render that keeps what the visitor ticked.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormField
  alias KilnCMSWeb.BlockComponents

  import KilnCMS.FormFixtures, only: [admin: 0, form!: 0]

  defp field(type, attrs \\ []) do
    struct!(
      FormField,
      Keyword.merge(
        [
          name: "f",
          label: "Label",
          field_type: type,
          required: false,
          options: ["A", "B"],
          help_text: nil,
          placeholder: nil,
          default_value: nil,
          width: :full,
          min_value: nil,
          max_value: nil,
          step: nil
        ],
        attrs
      )
    )
  end

  defp render_field(field, extra \\ []) do
    assigns = Keyword.merge([field: field, id_prefix: "p"], extra)

    (&BlockComponents.public_form_field/1)
    |> render_component(assigns)
    |> LazyHTML.from_fragment()
  end

  defp q(doc, selector), do: LazyHTML.query(doc, selector)
  defp count(doc, selector), do: doc |> q(selector) |> Enum.count()
  defp attr(doc, selector, name), do: doc |> q(selector) |> LazyHTML.attribute(name)

  test "every field type renders its own control, never the text-input fallback" do
    expected = %{
      string: ~s(input[type="text"][name="f"]),
      text: ~s(textarea[name="f"]),
      email: ~s(input[type="email"][name="f"]),
      integer: ~s(input[type="number"][name="f"]),
      boolean: ~s(input[type="checkbox"][name="f"]),
      date: ~s(input[type="date"][name="f"]),
      select: ~s(select[name="f"]),
      radio: ~s(fieldset input[type="radio"][name="f"]),
      checkboxes: ~s(fieldset input[type="checkbox"][name="f[]"]),
      phone: ~s(input[type="tel"][name="f"]),
      url: ~s(input[type="url"][name="f"]),
      hidden: ~s(input[type="hidden"][name="f"]),
      number: ~s(input[type="number"][name="f"][step="any"]),
      rating: ~s(fieldset input[type="radio"][name="f"][value="5"])
    }

    # A new type in the resource must get a row here (and a renderer).
    assert Enum.sort(Map.keys(expected)) == Enum.sort(FormField.field_types())

    for {type, selector} <- expected do
      doc = render_field(field(type))
      assert count(doc, selector) >= 1, "#{type} did not render #{selector}"

      if type not in [:string, :hidden] do
        assert count(doc, ~s(input[type="text"][name="f"])) == 0,
               "#{type} fell through to the text input"
      end
    end
  end

  test "radio, checkboxes and rating are fieldsets captioned by a legend" do
    for type <- [:radio, :checkboxes, :rating] do
      doc = render_field(field(type, required: true))
      assert doc |> q("fieldset legend") |> LazyHTML.text() =~ "Label"
      # The shared <label for> is not used: there is no single control to point at.
      assert count(doc, "label[for]") == 0
    end
  end

  test "checkboxes: no per-input required, aria-required on the fieldset, name[]" do
    doc = render_field(field(:checkboxes, required: true))

    assert count(doc, ~s(input[type="checkbox"][name="f[]"])) == 2
    assert count(doc, "input[required]") == 0
    assert attr(doc, "fieldset", "aria-required") == ["true"]

    optional = render_field(field(:checkboxes))
    assert attr(optional, "fieldset", "aria-required") == []
  end

  test "checkboxes: a submitted list checks those boxes, a default checks one" do
    doc = render_field(field(:checkboxes, options: ["A", "B", "C"]), value: ["A", "C"])
    assert attr(doc, "input[checked]", "value") == ["A", "C"]

    doc = render_field(field(:checkboxes, default_value: "B"))
    assert attr(doc, "input[checked]", "value") == ["B"]
  end

  test "radio: the submitted option is selected and required lands on the inputs" do
    doc = render_field(field(:radio, required: true), value: "B")
    assert attr(doc, "input[checked]", "value") == ["B"]
    assert count(doc, ~s(input[type="radio"][required])) == 2
  end

  test "an error is described on the fieldset" do
    for type <- [:radio, :checkboxes, :rating] do
      doc = render_field(field(type), error: "is required")
      assert attr(doc, "fieldset", "aria-invalid") == ["true"]
      assert attr(doc, "fieldset", "aria-describedby") == ["p-f-error"]
      assert count(doc, "#p-f-error") == 1
    end
  end

  test "rating: stars from max_value (default 5), labelled through gettext, value checked" do
    assert "#{count(render_field(field(:rating)), ~s(input[type="radio"]))}" == "5"

    doc = render_field(field(:rating, max_value: 3.0), value: "2")
    assert count(doc, ~s(input[type="radio"])) == 3
    assert attr(doc, "input[checked]", "value") == ["2"]
    assert LazyHTML.text(doc) =~ "2 of 3"
  end

  test "number carries min, max and step; phone and url use their input types" do
    doc = render_field(field(:number, min_value: 1.5, max_value: 10.0, step: 0.5))
    assert attr(doc, "input", "min") == ["1.5"]
    assert attr(doc, "input", "max") == ["10.0"]
    assert attr(doc, "input", "step") == ["0.5"]

    assert count(render_field(field(:phone)), ~s(input[type="tel"])) == 1
    assert count(render_field(field(:url)), ~s(input[type="url"])) == 1
  end

  test "hidden renders a bare input: no label, no help text, the default as value" do
    doc = render_field(field(:hidden, default_value: "utm", help_text: "secret help"))
    assert attr(doc, ~s(input[type="hidden"]), "value") == ["utm"]
    assert count(doc, "label") == 0
    refute LazyHTML.text(doc) =~ "secret help"
  end

  describe "invalid re-render through the controller" do
    test "keeps checked boxes, the selected radio and the rating" do
      form = form!()
      actor = admin()

      for attrs <- [
            %{
              name: "colours",
              label: "Colours",
              field_type: :checkboxes,
              options: ["R", "G", "B"]
            },
            %{name: "size", label: "Size", field_type: :radio, options: ["S", "L"]},
            %{name: "stars", label: "Stars", field_type: :rating, max_value: 4.0}
          ] do
        CMS.create_form_field!(Map.put(attrs, :form_id, form.id), actor: actor)
      end

      conn =
        build_conn()
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{
          "email" => "nope",
          "colours" => ["", "R", "B"],
          "size" => "L",
          "stars" => "3"
        })

      assert html_response(conn, 422)
      d = LazyHTML.from_document(conn.resp_body)
      p = "kiln-form-#{form.slug}"

      assert d |> q("##{p}-colours input[checked]") |> LazyHTML.attribute("value") == ["R", "B"]
      assert d |> q("##{p}-size input[checked]") |> LazyHTML.attribute("value") == ["L"]
      assert d |> q("##{p}-stars input[checked]") |> LazyHTML.attribute("value") == ["3"]
    end

    test "a list posted for a non-checkbox field is not echoed back" do
      form = form!()

      conn =
        build_conn()
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => ["a", "b"]})

      assert html_response(conn, 422)
      refute conn.resp_body =~ ~s(value="a")
    end
  end
end
