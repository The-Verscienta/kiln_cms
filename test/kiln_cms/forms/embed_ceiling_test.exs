defmodule KilnCMS.Forms.EmbedCeilingTest do
  @moduledoc """
  The matching rule and the cap switch of `KilnCMS.Forms.EmbedCeiling` (#1133),
  on their own. The write refusal and the served header are pinned through the
  real resources and pipeline in
  `test/kiln_cms_web/controllers/form_embed_ceiling_test.exs`.

  `async: false` because the cap and the ceiling are application env, which is
  VM-global; `config/test.exs` pins `:embed_origins` to `["https://embedder.test"]`
  and leaves the cap unset (off).
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Forms.EmbedCeiling

  setup do
    previous_lock = Application.get_env(:kiln_cms, :embed_origins_locked)
    previous_ceiling = Application.get_env(:kiln_cms, :embed_origins)

    on_exit(fn ->
      restore(:embed_origins_locked, previous_lock)
      restore(:embed_origins, previous_ceiling)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kiln_cms, key)
  defp restore(key, value), do: Application.put_env(:kiln_cms, key, value)

  defp lock!(ceiling) do
    Application.put_env(:kiln_cms, :embed_origins_locked, true)
    Application.put_env(:kiln_cms, :embed_origins, ceiling)
  end

  describe "covers?/2 — one ceiling entry against one tenant entry" do
    test "exact origin" do
      assert EmbedCeiling.covers?("https://acme.com", "https://acme.com")
      assert EmbedCeiling.covers?("https://ACME.com", "https://acme.COM")
      refute EmbedCeiling.covers?("https://acme.com", "https://acme.org")
      refute EmbedCeiling.covers?("https://acme.com", "https://notacme.com")
    end

    test "scheme: a scheme-less ceiling entry covers either, a schemed one only its own" do
      assert EmbedCeiling.covers?("acme.com", "https://acme.com")
      assert EmbedCeiling.covers?("acme.com", "http://acme.com")
      refute EmbedCeiling.covers?("https://acme.com", "http://acme.com")
    end

    test "port: absent covers absent, `*` covers any, a number only itself" do
      assert EmbedCeiling.covers?("https://acme.com", "https://acme.com")
      refute EmbedCeiling.covers?("https://acme.com", "https://acme.com:8443")
      refute EmbedCeiling.covers?("https://acme.com:8443", "https://acme.com")
      assert EmbedCeiling.covers?("https://acme.com:8443", "https://acme.com:8443")
      assert EmbedCeiling.covers?("https://acme.com:*", "https://acme.com:8443")
      assert EmbedCeiling.covers?("https://acme.com:*", "https://acme.com")
    end

    test "a wildcard ceiling entry covers proper subdomains, not the apex" do
      assert EmbedCeiling.covers?("https://*.acme.com", "https://blog.acme.com")
      assert EmbedCeiling.covers?("https://*.acme.com", "https://a.b.acme.com")
      # CSP's reading: `*.acme.com` is not `acme.com`. The operator names the
      # apex separately if they mean it.
      refute EmbedCeiling.covers?("https://*.acme.com", "https://acme.com")
      refute EmbedCeiling.covers?("https://*.acme.com", "https://notacme.com")
      refute EmbedCeiling.covers?("https://*.acme.com", "https://acme.com.evil.test")
    end

    test "a wildcard TENANT entry needs a wildcard at least as wide above it" do
      assert EmbedCeiling.covers?("https://*.acme.com", "https://*.acme.com")
      assert EmbedCeiling.covers?("https://*.acme.com", "https://*.eu.acme.com")
      # A plain apex does not cover its own wildcard — that would grant every
      # subdomain the operator did not name.
      refute EmbedCeiling.covers?("https://acme.com", "https://*.acme.com")
      refute EmbedCeiling.covers?("https://blog.acme.com", "https://*.acme.com")
      refute EmbedCeiling.covers?("https://*.eu.acme.com", "https://*.acme.com")
    end

    test "a bare `*` mixed into a ceiling covers nothing (parse_env discards such a list anyway)" do
      refute EmbedCeiling.covers?("*", "https://acme.com")
    end

    test "garbage on either side is not covered" do
      refute EmbedCeiling.covers?("", "https://acme.com")
      refute EmbedCeiling.covers?("https://acme.com", "")
      refute EmbedCeiling.covers?("https://acme.com", "https://acme.com; script-src *")
    end
  end

  describe "outside/2 — the pure half" do
    test ":all covers everything" do
      assert EmbedCeiling.outside(["https://anything.test"], :all) == []
    end

    test "an empty ceiling covers nothing" do
      assert EmbedCeiling.outside(["https://a.test", "https://b.test"], []) ==
               ["https://a.test", "https://b.test"]
    end

    test "names the entries outside, in the order given" do
      ceiling = ["https://ok.test", "https://*.acme.com"]

      assert EmbedCeiling.outside(
               [
                 "https://evil.test",
                 "https://ok.test",
                 "https://blog.acme.com",
                 "https://acme.com"
               ],
               ceiling
             ) == ["https://evil.test", "https://acme.com"]
    end

    test "an unparseable ceiling entry is skipped, not treated as covering" do
      assert EmbedCeiling.outside(["https://a.test"], ["", "https://a.test"]) == []
      assert EmbedCeiling.outside(["https://a.test"], [""]) == ["https://a.test"]
    end
  end

  describe "the switch" do
    test "cap off: nothing is outside and clamp is the identity, whatever the ceiling" do
      Application.put_env(:kiln_cms, :embed_origins_locked, false)
      Application.put_env(:kiln_cms, :embed_origins, [])

      refute EmbedCeiling.locked?()
      assert EmbedCeiling.outside(["https://anywhere.test"]) == []
      assert EmbedCeiling.clamp(["https://anywhere.test"]) == ["https://anywhere.test"]
    end

    test "cap unset at all reads as off — the default a deployment ships with" do
      Application.delete_env(:kiln_cms, :embed_origins_locked)
      refute EmbedCeiling.locked?()
    end

    test "cap on: outside/1 and clamp/1 read the deployment ceiling" do
      lock!(["https://embedder.test"])

      assert EmbedCeiling.locked?()
      assert EmbedCeiling.ceiling() == ["https://embedder.test"]

      assert EmbedCeiling.outside(["https://embedder.test", "https://other.test"]) ==
               ["https://other.test"]

      assert EmbedCeiling.clamp(["https://embedder.test", "https://other.test"]) ==
               ["https://embedder.test"]

      # Clamped to nothing is `[]` — which the header renders as `'self'`.
      assert EmbedCeiling.clamp(["https://other.test"]) == []
      assert EmbedCeiling.clamp([]) == []
    end

    test "cap on with EMBED_ORIGINS=* is a ceiling of everything" do
      lock!(:all)
      assert EmbedCeiling.outside(["https://anywhere.test"]) == []
    end

    test "cap on with EMBED_ORIGINS unset is a ceiling of nothing" do
      lock!([])
      assert EmbedCeiling.outside(["https://anywhere.test"]) == ["https://anywhere.test"]
    end
  end
end
