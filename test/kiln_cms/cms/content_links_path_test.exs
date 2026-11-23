defmodule KilnCMS.CMS.ContentLinksPathTest do
  @moduledoc """
  An edge's `field` is the dotted definition path of a reference inside an
  item or row (#2282), and `ContentLink.field` is capped at
  `KilnCMS.Limits.line/0`. A path that cannot be stored implies no edge, so a
  save never raises on it.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.ContentLinks

  @target Ecto.UUID.generate()
  @snapshot %{"id" => @target, "type" => "page", "slug" => "s", "title" => "T"}

  defp cta(name),
    do: %{
      field_type: :reference,
      name: name,
      group_fields: [],
      item_setting: false,
      target_type: "page"
    }

  defp flexible(name, type_name, sub),
    do: %{
      field_type: :flexible,
      name: name,
      item_types: [%{field_type: :group, name: type_name, group_fields: [sub]}]
    }

  test "a path within the cap implies its edge" do
    definition = flexible("sections", "hero", cta("cta"))
    value = %{"sections" => [%{"_type" => "hero", "cta" => @snapshot}]}

    assert [%{field: "sections.hero.cta", target_id: @target}] =
             ContentLinks.desired(value, [definition])
  end

  test "a path past the cap implies no edge and does not raise" do
    long = String.duplicate("x", 400)
    definition = flexible(long, long, cta(long))
    value = %{long => [%{"_type" => long, long => @snapshot}]}

    assert String.length(Enum.join([long, long, long], ".")) > KilnCMS.Limits.line()
    assert [] == ContentLinks.desired(value, [definition])
  end

  test "a path exactly at the cap is kept" do
    # name + "." + type + "." + sub = 1000
    name = String.duplicate("a", 333)
    type = String.duplicate("b", 333)
    sub = String.duplicate("c", 332)
    definition = flexible(name, type, cta(sub))
    value = %{name => [%{"_type" => type, sub => @snapshot}]}

    assert [%{field: field}] = ContentLinks.desired(value, [definition])
    assert String.length(field) == KilnCMS.Limits.line()
  end
end
