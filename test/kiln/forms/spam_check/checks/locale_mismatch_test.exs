defmodule Kiln.Forms.SpamCheck.Checks.LocaleMismatchTest do
  use ExUnit.Case, async: true

  alias Kiln.Forms.SpamCheck.Checks.LocaleMismatch
  alias Kiln.Forms.SpamCheck.Context

  test "no locale declared is not flagged" do
    ctx = Context.new(%{"message" => String.duplicate("Привет мир! ", 5)})
    assert LocaleMismatch.check(ctx) == :ok
  end

  test "an unrecognized locale is not flagged (never assumed Latin)" do
    ctx =
      Context.new(%{"message" => String.duplicate("Привет мир! ", 5)}, locale: "ru")

    assert LocaleMismatch.check(ctx) == :ok
  end

  test "matching script and locale is not flagged" do
    ctx =
      Context.new(%{"message" => "I would like a quote for a new fence please."}, locale: "en")

    assert LocaleMismatch.check(ctx) == :ok
  end

  test "a short foreign snippet (a name, a brand) does not tip it" do
    ctx = Context.new(%{"message" => "My name is Наташа, please call me back."}, locale: "en")
    assert LocaleMismatch.check(ctx) == :ok
  end

  test "predominantly non-Latin text against a Latin-script locale is flagged" do
    ctx =
      Context.new(
        %{"message" => String.duplicate("Купите дешево сейчас переходите по ссылке ", 3)},
        locale: "en"
      )

    assert {:flag, :script_mismatch, weight} = LocaleMismatch.check(ctx)
    assert weight > 0
  end

  test "predominantly CJK text against a Latin-script locale is flagged" do
    ctx = Context.new(%{"message" => String.duplicate("购买便宜的药品现在点击这里访问网站谢谢您", 2)}, locale: "fr")
    assert {:flag, :script_mismatch, _} = LocaleMismatch.check(ctx)
  end
end
