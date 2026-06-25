defmodule Kiln.Block.DslTest do
  @moduledoc "The Kiln.Block Spark DSL fans a block definition out to an embedded resource."
  use ExUnit.Case, async: true

  alias KilnCMS.Blocks.Heading

  describe "Info introspection" do
    test "exposes the block name (the _type discriminator) and version" do
      assert Kiln.Block.Info.name(Heading) == :heading
      assert Kiln.Block.Info.version(Heading) == 1
    end

    test "exposes the declared fields" do
      names = Heading |> Kiln.Block.Info.fields() |> Enum.map(& &1.name)
      assert :text in names
      assert :level in names
    end
  end

  describe "generated Ash embedded resource" do
    test "fields become Ash attributes with the mapped types" do
      assert %Ash.Resource.Attribute{type: Ash.Type.String} =
               Ash.Resource.Info.attribute(Heading, :text)

      assert %Ash.Resource.Attribute{type: Ash.Type.Integer} =
               Ash.Resource.Info.attribute(Heading, :level)
    end

    test "required: true ⇒ allow_nil? false; otherwise nullable" do
      assert Ash.Resource.Info.attribute(Heading, :text).allow_nil? == false
      assert Ash.Resource.Info.attribute(Heading, :level).allow_nil? == true
    end

    test "the module is an embedded resource with a writable id" do
      assert Ash.Resource.Info.embedded?(Heading)
      assert Ash.Resource.Info.attribute(Heading, :id).writable?
    end

    test "rich_text fields map to an array of PT maps" do
      assert %Ash.Resource.Attribute{type: {:array, Ash.Type.Map}} =
               Ash.Resource.Info.attribute(KilnCMS.Blocks.RichText, :body)
    end
  end

  describe "render contract" do
    test "render/2 dispatches by struct and is total over surfaces" do
      heading = %Heading{text: "Hi <there>", level: 3}

      assert heading |> Heading.render(:web) |> IO.iodata_to_binary() ==
               "<h3>Hi &lt;there&gt;</h3>"

      assert Heading.render(heading, :json) == %{
               "_type" => "heading",
               "text" => "Hi <there>",
               "level" => 3
             }

      # unhandled surface contributes nothing rather than raising (decision A4)
      assert Heading.render(heading, :json_ld) == nil
    end

    test "level is clamped to a valid heading range" do
      assert %Heading{text: "x", level: 99} |> Heading.render(:web) |> IO.iodata_to_binary() ==
               "<h2>x</h2>"
    end
  end
end
