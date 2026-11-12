defmodule KilnCMS.Forms.FieldTypesTest do
  @moduledoc """
  The form field types added in #2261 (`radio`, `checkboxes`, `phone`, `url`,
  `hidden`, `number`, `rating`): per type, a valid value, an invalid one,
  required-blank, optional-blank and a wrong shape — plus the resource rules
  of `KilnCMS.CMS.Validations.FormFieldConfig` and the webhook payload.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Forms

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ft-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form!(field, actor \\ nil) do
    actor = actor || admin()

    form =
      CMS.create_form!(%{name: "T", slug: "ft-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    CMS.create_form_field!(
      Map.merge(%{form_id: form.id, name: "f", label: "F", position: 0}, field),
      actor: actor
    )

    Forms.get_active(form.slug)
  end

  defp submit(form, value), do: Forms.submit(form, %{"f" => value})
  defp submit(form), do: Forms.submit(form, %{})

  defp data(form, value) do
    assert {:ok, submission} = submit(form, value)
    submission.data
  end

  defp error(form, value) do
    assert {:error, %{"f" => message}} = submit(form, value)
    message
  end

  # Every type: blank handling + the #751 shape guard.
  describe "required, optional and wrong shape" do
    for type <- [:radio, :phone, :url, :hidden, :number, :rating] do
      @type_under_test type

      test "#{type}: required blank is refused, optional blank is skipped" do
        options = if @type_under_test == :radio, do: ["a", "b"], else: []

        required =
          form!(%{
            field_type: @type_under_test,
            options: options,
            required: @type_under_test != :hidden
          })

        optional = form!(%{field_type: @type_under_test, options: options})

        if @type_under_test != :hidden do
          for blank <- [nil, "", "  "] do
            assert "is required" == error(required, blank)
          end
        end

        assert {:ok, %{data: data}} = submit(optional, "  ")
        assert data == %{}
        assert {:ok, %{data: %{}}} = submit(optional)
      end

      test "#{type}: a list or map is not valid" do
        options = if @type_under_test == :radio, do: ["a", "b"], else: []
        form = form!(%{field_type: @type_under_test, options: options})

        for shape <- [[], [""], ["a"], %{"a" => "b"}] do
          assert "is not valid" == error(form, shape)
        end
      end
    end

    test "a field type with no cast clause raises rather than storing anything" do
      assert_raise FunctionClauseError, fn ->
        Forms.submit(
          %{
            active: true,
            id: nil,
            fields: [%KilnCMS.CMS.FormField{name: "f", field_type: :nope}]
          },
          %{"f" => "x"}
        )
      end
    end
  end

  describe "radio" do
    setup do
      %{form: form!(%{field_type: :radio, options: ["red", "blue"]})}
    end

    test "valid", %{form: form} do
      assert %{"f" => "blue"} == data(form, " blue ")
    end

    test "invalid", %{form: form} do
      assert "is not one of the allowed options" == error(form, "green")
    end
  end

  describe "checkboxes" do
    setup do
      %{form: form!(%{field_type: :checkboxes, options: ["a", "b", "c"]})}
    end

    test "a list is stored in options order, deduplicated", %{form: form} do
      assert %{"f" => ["a", "c"]} == data(form, ["c", "a", "a"])
    end

    test "a lone string is one box; blank sentinels are dropped", %{form: form} do
      assert %{"f" => ["b"]} == data(form, "b")
      assert %{"f" => ["b"]} == data(form, ["", "b"])
    end

    test "an unknown option is refused", %{form: form} do
      assert "is not one of the allowed options" == error(form, ["a", "z"])
    end

    test "non-string elements, nested lists, maps and scalars are not valid", %{form: form} do
      for bad <- [["a", 1], ["a", ["b"]], %{"a" => "b"}, 5, true] do
        assert "is not valid" == error(form, bad)
      end
    end

    test "more entries than options is not valid", %{form: form} do
      assert "is not valid" == error(form, ["a", "a", "a", "a"])
    end

    test "[] and an all-blank list are blank: optional skips, required refuses" do
      optional = form!(%{field_type: :checkboxes, options: ["a"]})
      required = form!(%{field_type: :checkboxes, options: ["a"], required: true})

      for blank <- [[], [""], ["", "  "]] do
        assert %{} == data(optional, blank)
        assert "is required" == error(required, blank)
      end
    end

    test "the webhook payload carries the list" do
      form = form!(%{field_type: :checkboxes, options: ["a", "b"]})

      CMS.create_webhook_endpoint!(
        %{url: "https://example.test/hook", events: ["form.submitted"]},
        actor: admin()
      )

      assert {:ok, submission} = submit(form, ["b", "a"])
      assert submission.data == %{"f" => ["a", "b"]}

      assert [delivery] = CMS.recent_webhook_deliveries!(authorize?: false)
      assert delivery.payload["data"] == %{"f" => ["a", "b"]}
    end
  end

  describe "phone" do
    setup do
      %{form: form!(%{field_type: :phone})}
    end

    test "valid, stored as typed (trimmed)", %{form: form} do
      assert %{"f" => "+1 (555) 010-0199"} == data(form, " +1 (555) 010-0199 ")
      assert %{"f" => "555.010.0199"} == data(form, "555.010.0199")
    end

    test "invalid", %{form: form} do
      for bad <- [
            "abc123456",
            "12345",
            "1234567890123456",
            "555-010-0199 ext 5",
            String.duplicate("1", 40),
            "+++++++"
          ] do
        assert "must be a phone number" == error(form, bad), inspect(bad)
      end
    end
  end

  describe "url" do
    setup do
      %{form: form!(%{field_type: :url})}
    end

    test "valid", %{form: form} do
      assert %{"f" => "https://example.com/a?b=1"} == data(form, " https://example.com/a?b=1 ")
      assert %{"f" => "HTTP://example.com"} == data(form, "HTTP://example.com")
    end

    test "invalid", %{form: form} do
      for bad <- [
            "javascript:alert(1)",
            "data:text/html,x",
            "ftp://example.com",
            "example.com",
            "http://",
            "http:///path",
            "https://user:pw@example.com",
            "http://a@b.test",
            "https://exa mple.com",
            "https://example.com/\nx",
            "https://example.com/" <> String.duplicate("a", 2_100)
          ] do
        assert "must be a URL starting with http:// or https://" == error(form, bad), inspect(bad)
      end
    end
  end

  describe "hidden" do
    setup do
      %{form: form!(%{field_type: :hidden})}
    end

    test "valid: free text, trimmed, not forced to the default", %{form: form} do
      assert %{"f" => "utm"} == data(form, " utm ")
    end

    test "invalid: too long", %{form: form} do
      assert "is too long" == error(form, String.duplicate("a", 1_001))
    end
  end

  describe "number" do
    test "valid, whole values stay integers" do
      form = form!(%{field_type: :number})

      for {input, expected} <- [
            {"5", 5},
            {"+5", 5},
            {"-0", 0},
            {"1.0", 1},
            {"2.50", 2.5},
            {" 7 ", 7},
            {3, 3},
            {1.5, 1.5},
            {2.0, 2}
          ] do
        assert %{"f" => expected} == data(form, input)
        assert is_integer(expected) == is_integer(data(form, input)["f"])
      end
    end

    test "invalid shapes are refused" do
      form = form!(%{field_type: :number})

      for bad <- [
            "abc",
            "1e400",
            "1e3",
            "nan",
            "inf",
            ".5",
            "5.",
            "1_000",
            "1,5",
            "0x10",
            String.duplicate("1", 65),
            true
          ] do
        assert "must be a number" == error(form, bad), inspect(bad)
      end
    end

    test "min, max and step are enforced" do
      form = form!(%{field_type: :number, min_value: 1.0, max_value: 10.0, step: 0.5})

      assert %{"f" => 1} == data(form, "1")
      assert %{"f" => 2.5} == data(form, "2.5")
      assert "must be at least 1" == error(form, "0.5")
      assert "must be at most 10" == error(form, "10.5")
      assert "must be a multiple of 0.5" == error(form, "2.25")
    end

    test "step aligns to min, and float error does not refuse 0.3 on a 0.1 step" do
      aligned = form!(%{field_type: :number, min_value: 1.0, step: 2.0})
      assert %{"f" => 5} == data(aligned, "5")
      assert "must be a multiple of 2" == error(aligned, "4")

      tenths = form!(%{field_type: :number, step: 0.1})
      assert %{"f" => 0.3} == data(tenths, "0.3")
    end
  end

  describe "rating" do
    test "valid, default five stars" do
      form = form!(%{field_type: :rating})
      assert %{"f" => 3} == data(form, "3")
      assert %{"f" => 5} == data(form, 5)
    end

    test "invalid" do
      form = form!(%{field_type: :rating})

      for bad <- ["0", "6", "3.5", "x", "-1", 3.5, true] do
        assert "must be a rating from 1 to 5" == error(form, bad), inspect(bad)
      end
    end

    test "max_value sets the star count" do
      form = form!(%{field_type: :rating, max_value: 10.0})
      assert %{"f" => 10} == data(form, "10")
      assert "must be a rating from 1 to 10" == error(form, "11")
    end
  end

  describe "FormField validation (resource)" do
    defp create(attrs) do
      actor = admin()

      form =
        CMS.create_form!(%{name: "T", slug: "ft-#{System.unique_integer([:positive])}"},
          actor: actor
        )

      CMS.create_form_field(
        Map.merge(%{form_id: form.id, name: "f", label: "F"}, attrs),
        actor: actor
      )
    end

    defp invalid_on?({:error, %Ash.Error.Invalid{errors: errors}}, field),
      do: Enum.any?(errors, &(Map.get(&1, :field) == field))

    test "choice types need options" do
      for type <- [:select, :radio, :checkboxes] do
        assert invalid_on?(create(%{field_type: type, options: []}), :options)
        assert {:ok, _} = create(%{field_type: type, options: ["a"]})
      end
    end

    test "options must be non-blank, unique and bounded" do
      assert invalid_on?(create(%{field_type: :radio, options: ["a", " "]}), :options)
      assert invalid_on?(create(%{field_type: :radio, options: ["a", "a"]}), :options)

      assert invalid_on?(
               create(%{field_type: :radio, options: [String.duplicate("a", 1_001)]}),
               :options
             )

      many = Enum.map(1..51, &"o#{&1}")
      assert invalid_on?(create(%{field_type: :checkboxes, options: many}), :options)
    end

    test "number range: min <= max, step > 0" do
      assert invalid_on?(
               create(%{field_type: :number, min_value: 5.0, max_value: 1.0}),
               :min_value
             )

      assert invalid_on?(create(%{field_type: :number, step: 0.0}), :step)
      assert invalid_on?(create(%{field_type: :number, step: -1.0}), :step)
      assert {:ok, _} = create(%{field_type: :number, min_value: 1.0, max_value: 1.0, step: 0.5})
    end

    test "rating max is a whole number from 1 to 10; min/step are not for ratings" do
      for bad <- [0.0, 11.0, 2.5] do
        assert invalid_on?(create(%{field_type: :rating, max_value: bad}), :max_value)
      end

      assert invalid_on?(create(%{field_type: :rating, min_value: 1.0}), :max_value)
      assert {:ok, _} = create(%{field_type: :rating, max_value: 7.0})
      assert {:ok, _} = create(%{field_type: :rating})
    end

    test "other types carry no range" do
      for type <- [:string, :text, :email, :integer, :phone, :url, :hidden] do
        assert invalid_on?(create(%{field_type: type, min_value: 1.0}), :min_value)
        assert invalid_on?(create(%{field_type: type, step: 1.0}), :min_value)
      end
    end

    test "a hidden field can't be required" do
      assert invalid_on?(create(%{field_type: :hidden, required: true}), :required)
      assert {:ok, _} = create(%{field_type: :hidden})
    end

    test "new types can't take the honeypot's name" do
      for type <- [:url, :hidden, :phone] do
        assert invalid_on?(create(%{field_type: type, name: Forms.honeypot_field()}), :name)
      end
    end
  end

  # #2269: the HTML form translates the bounded refusals by parsing them back;
  # the JSON API returns the same English strings verbatim.
  describe "error_detail/1" do
    test "round-trips every bounded number refusal submit/3 produces" do
      cases = [
        {%{min_value: 3.0}, "2", {:min, "3"}},
        {%{min_value: 0.25}, "0.2", {:min, "0.25"}},
        {%{min_value: -3.0}, "-4", {:min, "-3"}},
        {%{max_value: 10.0}, "11", {:max, "10"}},
        {%{max_value: -0.5}, "0", {:max, "-0.5"}},
        {%{step: 0.25}, "0.3", {:step, "0.25"}},
        {%{min_value: 1.0, step: 2.0}, "4", {:step, "2"}}
      ]

      for {range, value, expected} <- cases do
        form = form!(Map.put(range, :field_type, :number))
        message = error(form, value)
        assert Forms.error_detail(message) == expected, inspect({range, value, message})
      end
    end

    test "round-trips the rating refusal, default and custom star count" do
      assert {:rating_max, "5"} == Forms.error_detail(error(form!(%{field_type: :rating}), "6"))

      ten = form!(%{field_type: :rating, max_value: 10.0})
      assert {:rating_max, "10"} == Forms.error_detail(error(ten, "11"))
    end

    test "any other message comes back as itself" do
      for message <- ["is required", "is too long", "must be a number", "must be at least ", "x"] do
        assert {:message, message} == Forms.error_detail(message)
      end
    end
  end

  describe "display_value/1" do
    test "lists join, floats lose their exponent, nil is empty" do
      assert Forms.display_value(["a", "b"]) == "a, b"
      assert Forms.display_value([]) == ""
      assert Forms.display_value(2.5) == "2.5"
      assert Forms.display_value(1.0e20) == "100000000000000000000"
      assert Forms.display_value(nil) == ""
      assert Forms.display_value(3) == "3"
      assert Forms.display_value(true) == "true"
      assert Forms.display_value("x") == "x"
    end
  end
end
