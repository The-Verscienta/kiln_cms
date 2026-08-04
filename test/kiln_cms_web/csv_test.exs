defmodule KilnCMSWeb.CSVTest do
  @moduledoc """
  The shared CSV writer (#618): RFC 4180 quoting plus the formula-prefix guard
  against CSV injection, extracted from `KilnCMSWeb.GovernanceController` so
  the analytics export doesn't reimplement (or forget) either.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.CSV

  describe "field/1" do
    test "passes plain values through unchanged" do
      assert CSV.field("hello") == "hello"
      assert CSV.field(42) == "42"
    end

    test "renders nil as an empty field" do
      assert CSV.field(nil) == ""
    end

    test "quotes a field containing a comma" do
      assert CSV.field("a,b") == ~s("a,b")
    end

    test "quotes and doubles embedded quotes" do
      assert CSV.field(~s(say "hi")) == ~s("say ""hi""")
    end

    test "quotes a field containing a newline or carriage return" do
      assert CSV.field("line1\nline2") == "\"line1\nline2\""
      assert CSV.field("line1\rline2") == "\"line1\rline2\""
    end

    for prefix <- ["=", "+", "-", "@", "\t"] do
      test "prefixes a formula-leading #{inspect(prefix)} to defeat CSV injection" do
        value = unquote(prefix) <> "SUM(A1:A9)"
        escaped = CSV.field(value)
        assert String.starts_with?(escaped, "'")
        assert escaped =~ value
      end
    end

    # "\r" is also an RFC 4180 wrap trigger, so (unlike the other guarded
    # prefixes) the prefixed value ends up quote-wrapped too.
    test "prefixes a leading carriage return, which also forces quoting" do
      assert CSV.field("\rSUM(A1:A9)") == "\"'\rSUM(A1:A9)\""
    end

    test "a formula-prefixed value that also needs quoting gets both guards" do
      # Leading "=" plus an embedded comma: the injection guard runs first, then
      # RFC 4180 quoting wraps the whole (now longer) value.
      assert CSV.field("=A1,B1") == "\"'=A1,B1\""
    end
  end

  describe "line/1" do
    test "joins fields with commas and terminates with CRLF" do
      assert CSV.line(["a", "b", "c"]) == "a,b,c\r\n"
    end

    test "escapes each field independently" do
      assert CSV.line(["plain", "has,comma", nil]) == ~s(plain,"has,comma",\r\n)
    end
  end
end
