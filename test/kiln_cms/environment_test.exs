defmodule KilnCMS.EnvironmentTest do
  @moduledoc """
  The console's environment indicator (#469) — off by default so production
  needs no configuration to stay unlabelled, and a tone name that can only ever
  resolve to something the design kit actually renders.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.Environment

  setup do
    previous = Application.get_env(:kiln_cms, :environment, [])
    on_exit(fn -> Application.put_env(:kiln_cms, :environment, previous) end)
    :ok
  end

  defp put(opts), do: Application.put_env(:kiln_cms, :environment, opts)

  describe "label/0" do
    test "is nil when unset, so production is unlabelled with nothing configured" do
      put(label: nil, tone: nil)
      refute Environment.label()
    end

    test "is nil for a variable that is set but empty or blank" do
      # A platform that exports every declared variable hands through `""` for
      # the ones with no value — which must read as "not set", not as a strip
      # whose label is a space.
      put(label: "")
      refute Environment.label()

      put(label: "   ")
      refute Environment.label()
    end

    test "trims what it shows" do
      put(label: "  staging\n")
      assert Environment.label() == "staging"
    end
  end

  describe "tone/0" do
    test "defaults to warning" do
      put(label: "staging", tone: nil)
      assert Environment.tone() == "warning"
    end

    test "accepts every tone the kit has a class for" do
      for tone <- Environment.tones() do
        put(label: "staging", tone: tone)
        assert Environment.tone() == tone
      end
    end

    test "normalizes case and whitespace" do
      put(label: "staging", tone: " ERROR ")
      assert Environment.tone() == "error"
    end

    test "falls back to the default and says so, rather than to silence" do
      # Fail to the *default*, not to nothing: a mistyped tone must still render
      # a strip, or a typo silently removes the warning it was meant to add.
      put(label: "staging", tone: "#ff0000")

      log = capture_log(fn -> assert Environment.tone() == "warning" end)
      assert log =~ "KILN_ENV_COLOR"
    end
  end
end
