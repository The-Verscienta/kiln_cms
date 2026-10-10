defmodule KilnCMS.Blocks.NewsletterSignupTest do
  @moduledoc "The newsletter sign-up block's serializers (#1870)."
  use ExUnit.Case, async: true

  alias Kiln.Block.JsonSchema
  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.NewsletterSignup
  alias KilnCMS.JsonSchemaValidator

  defp block(attrs \\ %{}), do: struct(%NewsletterSignup{_type: "newsletter_signup"}, attrs)

  defp web(block), do: block |> Blocks.render(:web) |> IO.iodata_to_binary()

  test "is a registered core block" do
    assert Blocks.registry()[:newsletter_signup] == NewsletterSignup
  end

  describe ":web" do
    test "is a real form posting email to the sign-up endpoint, with the honeypot" do
      html = web(block())

      assert html =~
               ~s(<form class="kiln-newsletter-signup" method="post" action="/newsletter/subscribe">)

      assert html =~ ~s(<input type="email" name="email" required autocomplete="email"/>)
      # The same name `NewsletterController.subscribe/2` checks, so a bot that
      # fills it gets the fake success instead of a subscriber row.
      assert html =~ ~s(name="#{KilnCMS.Forms.honeypot_field()}")
      assert html =~ "<button type=\"submit\">Subscribe</button>"
      refute html =~ ~s(name="name")
    end

    test "asks for a name only when told to" do
      assert web(block(%{collect_name: true})) =~ ~s(<input type="text" name="name")
    end

    test "escapes the editor's text and drops blank headings" do
      html =
        web(block(%{heading: "<b>News</b>", intro: "Ships & fixes", button_label: "Join \"us\""}))

      assert html =~ "<h2>&lt;b&gt;News&lt;/b&gt;</h2>"
      assert html =~ "<p>Ships &amp; fixes</p>"
      assert html =~ "Join &quot;us&quot;</button>"

      refute web(block(%{heading: "  ", intro: nil})) =~ "<h2>"
    end
  end

  describe ":json" do
    test "carries what a headless frontend needs to post" do
      json = Blocks.render(block(%{heading: "Releases", button_label: " "}), :json)

      assert json == %{
               "_type" => "newsletter_signup",
               "heading" => "Releases",
               "intro" => nil,
               "button_label" => "Subscribe",
               "collect_name" => false,
               "action" => "/newsletter/subscribe",
               "honeypot_field" => KilnCMS.Forms.honeypot_field()
             }
    end

    test "matches the exported schema" do
      schema = JsonSchema.for_module(NewsletterSignup)

      for attrs <- [%{}, %{heading: "H", intro: "I", button_label: "Go", collect_name: true}] do
        assert :ok = JsonSchemaValidator.validate(Blocks.render(block(attrs), :json), schema)
      end
    end
  end

  test "adds no structured data, and indexes its visible text" do
    assert Blocks.render(block(%{heading: "H"}), :json_ld) == nil

    assert Blocks.search_text(block(%{heading: "Get news", intro: " Monthly "})) ==
             "Get news Monthly"
  end
end
