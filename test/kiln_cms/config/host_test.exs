defmodule KilnCMS.Config.HostTest do
  @moduledoc """
  Pins the `PHX_HOST` normalization #1322 lifted out of `config/runtime.exs`.

  It was four lines inline there, read by one block. The split into per-concern
  fragments gave it a second reader — `runtime/prod/mailer.exs` falls back to it
  for the SMTP `HELO` name — and a local variable does not cross a fragment
  boundary, so the choice was one module or two copies. These cases are what the
  inline comment asserted and nothing checked: a scheme prefix or a trailing
  slash reaching the endpoint config breaks absolute URL generation and the
  LiveView socket's `Origin` check at once, silently.

  `async: false`: every case mutates the VM-wide `PHX_HOST`, which
  `test/config/runtime_env_flags_test.exs` evaluates `config/runtime.exs`
  against.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Config.Host

  setup do
    saved = System.get_env("PHX_HOST")

    on_exit(fn ->
      case saved do
        nil -> System.delete_env("PHX_HOST")
        value -> System.put_env("PHX_HOST", value)
      end
    end)

    :ok
  end

  defp canonical(nil) do
    System.delete_env("PHX_HOST")
    Host.canonical()
  end

  defp canonical(value) do
    System.put_env("PHX_HOST", value)
    Host.canonical()
  end

  test "a bare host is returned unchanged" do
    assert canonical("cms.example.com") == "cms.example.com"
  end

  test "a scheme prefix is stripped" do
    # Phoenix uses the configured host as-is, so `https://cms.example.com` would
    # be baked into generated URLs *and* into the socket Origin check.
    assert canonical("https://cms.example.com") == "cms.example.com"
    assert canonical("http://cms.example.com") == "cms.example.com"
  end

  test "a trailing slash is stripped" do
    assert canonical("cms.example.com/") == "cms.example.com"
  end

  test "a scheme and a trailing slash together are both stripped" do
    # The realistic misconfiguration: someone pastes the browser's address bar.
    assert canonical("https://cms.example.com/") == "cms.example.com"
  end

  test "unset falls back to Phoenix's generated default" do
    # Kept deliberately wrong-looking: an operator who never set PHX_HOST should
    # see `example.com` in a generated URL rather than something plausible.
    assert canonical(nil) == "example.com"
  end

  test "only a leading scheme is stripped, not one appearing later" do
    # `String.replace_leading/3`, not `replace/3` — a host that merely contains
    # the substring must survive intact.
    assert canonical("cms.example.com/http://x") == "cms.example.com/http://x"
  end

  test "the two fragments that read it agree by construction" do
    # The whole reason this module exists: `runtime/prod/web.exs` (endpoint
    # host, check_origin, tenant base host) and `runtime/prod/mailer.exs` (the
    # HELO fallback) must not drift apart. Neither may re-derive it inline.
    for path <- ~w(config/runtime/prod/web.exs config/runtime/prod/mailer.exs) do
      source = File.read!(path)

      assert source =~ "KilnCMS.Config.Host.canonical()",
             "#{path} should read the shared host, not derive its own."

      refute source =~ ~s|System.get_env("PHX_HOST")|,
             "#{path} derives PHX_HOST inline again — that is the copy #1322 removed."
    end
  end
end
