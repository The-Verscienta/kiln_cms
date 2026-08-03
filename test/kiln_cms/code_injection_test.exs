defmodule KilnCMS.CodeInjectionTest do
  @moduledoc """
  Per-site code injection (#490). The feature is stored XSS by design, so the
  tests are mostly about the boundaries: who may write, where it renders, and
  whether the CSP that has to permit it actually does.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CodeInjection

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "inject-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp save!(attrs, actor) do
    CMS.save_site_code_injection!(attrs, actor: actor, tenant: org_id())
  end

  setup do
    on_exit(fn -> KilnCMS.Cache.bust_code_injection(org_id()) end)
    :ok
  end

  describe "inline script hashes" do
    test "hashes each inline body and skips src-only and empty scripts" do
      hashes =
        CodeInjection.inline_hashes([
          ~s(<script src="https://plausible.io/js/script.js" defer></script>),
          "<script>console.log('hi')</script>",
          "<script>   </script>"
        ])

      assert hashes == [Base.encode64(:crypto.hash(:sha256, "console.log('hi')"))]
    end

    test "hashes the exact bytes a browser would, entities included" do
      body = "if (a &lt; b) { go(); }"
      [hash] = CodeInjection.inline_hashes(["<script>#{body}</script>"])

      # No entity decoding: CSP hashes the raw text content of the element.
      assert hash == Base.encode64(:crypto.hash(:sha256, body))
    end

    # `[^>]*` stops the start tag at the first `>`, so an attribute value
    # containing one splits the element early. That matches how a browser's
    # tokenizer behaves for an unquoted `>`, and differs from it for a quoted
    # one — pinned here so the limitation is recorded rather than assumed. The
    # consequence is a hash that doesn't match, i.e. a blocked script, which is
    # the safe direction.
    test "an attribute containing > splits the start tag early" do
      [hash] = CodeInjection.inline_hashes(["<script data-x=\"a>b\">real()</script>"])

      refute hash == Base.encode64(:crypto.hash(:sha256, "real()"))
    end

    test "handles several scripts, an unclosed one, and dedupes" do
      hashes =
        CodeInjection.inline_hashes([
          "<script>one()</script><script>two()</script>",
          "<script>one()</script>",
          "<script>tail()"
        ])

      assert length(hashes) == 3
      assert Base.encode64(:crypto.hash(:sha256, "one()")) in hashes
      assert Base.encode64(:crypto.hash(:sha256, "tail()")) in hashes
    end

    test "no scripts means no hashes" do
      assert CodeInjection.inline_hashes(["<meta name=\"verify\" content=\"x\" />", nil, ""]) ==
               []
    end
  end

  describe "saving" do
    test "derives script_hashes from the snippet on write" do
      row = save!(%{"head_html" => "<script>track()</script>"}, user(:admin))

      assert row.script_hashes == [Base.encode64(:crypto.hash(:sha256, "track()"))]
    end

    # The hashes are what the CSP authorizes, so they must be a function of the
    # HTML and never an input — otherwise a caller allows a script the snippet
    # does not contain.
    test "script_hashes cannot be supplied by the caller" do
      assert_raise Ash.Error.Invalid, ~r/script_hashes/, fn ->
        save!(
          %{"head_html" => "<script>real()</script>", "script_hashes" => ["forged"]},
          user(:admin)
        )
      end

      # And the derived value is still exactly what the snippet contains.
      row = save!(%{"head_html" => "<script>real()</script>"}, user(:admin))
      assert row.script_hashes == [Base.encode64(:crypto.hash(:sha256, "real()"))]
    end

    # A save touching only the footer must still re-hash the head, or the head's
    # script silently loses its authorization.
    test "re-hashes both fields when only one is edited" do
      actor = user(:admin)
      save!(%{"head_html" => "<script>head()</script>"}, actor)

      row =
        save!(
          %{"head_html" => "<script>head()</script>", "footer_html" => "<script>foot()</script>"},
          actor
        )

      assert length(row.script_hashes) == 2
    end

    test "an editor cannot write code injection" do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_code_injection(%{"head_html" => "<script>x()</script>"},
                 actor: user(:editor),
                 tenant: org_id()
               )
    end

    test "every change is recorded in the version trail" do
      actor = user(:admin)
      save!(%{"head_html" => "<script>one()</script>"}, actor)
      save!(%{"head_html" => "<script>two()</script>"}, actor)

      versions =
        CMS.list_code_injection_versions!(authorize?: false, tenant: org_id())

      assert length(versions) >= 2
      assert Enum.any?(versions, &(&1.user_id == actor.id))
    end
  end

  describe "CSP origin validation" do
    test "accepts full https origins, wildcards and ports" do
      row =
        save!(
          %{
            "script_src" => [
              "https://plausible.io",
              "https://*.matomo.cloud",
              "http://localhost:8000"
            ],
            "head_html" => nil
          },
          user(:admin)
        )

      assert length(row.script_src) == 3
    end

    # Each of these is valid CSP syntax that would switch off the policy this
    # list is meant to extend.
    test "refuses keyword sources and bare wildcards" do
      for bad <- ["'unsafe-inline'", "'unsafe-eval'", "*", "data:", "'self'"] do
        assert {:error, _} =
                 CMS.save_site_code_injection(%{"script_src" => [bad]},
                   actor: user(:admin),
                   tenant: org_id()
                 ),
               "#{bad} should be refused"
      end
    end

    # A value carrying a `;` or a newline would end the directive and let the
    # rest of the header be chosen by the author.
    test "refuses values that could break out of the directive" do
      for bad <- [
            "https://ok.example; script-src *",
            "https://ok.example\nx-frame-options: none",
            "https://ok.example, *"
          ] do
        assert {:error, _} =
                 CMS.save_site_code_injection(%{"connect_src" => [bad]},
                   actor: user(:admin),
                   tenant: org_id()
                 ),
               "#{inspect(bad)} should be refused"
      end
    end

    test "refuses plaintext http to a non-local host" do
      assert {:error, _} =
               CMS.save_site_code_injection(%{"img_src" => ["http://tracker.example"]},
                 actor: user(:admin),
                 tenant: org_id()
               )
    end
  end

  describe "resolution" do
    test "an unconfigured site resolves to the empty struct" do
      injection = CodeInjection.for_org(org_id())

      refute CodeInjection.any?(injection)

      assert CodeInjection.csp_sources(injection) == %{
               script_src: [],
               connect_src: [],
               img_src: []
             }
    end

    test "a disabled site emits nothing and widens nothing" do
      save!(
        %{
          "head_html" => "<script>track()</script>",
          "script_src" => ["https://plausible.io"],
          "enabled" => false
        },
        user(:admin)
      )

      injection = CodeInjection.for_org(org_id())

      refute CodeInjection.any?(injection)
      assert CodeInjection.csp_sources(injection).script_src == []
    end

    test "csp_sources carries origins and hashes together" do
      save!(
        %{
          "head_html" => "<script>track()</script>",
          "script_src" => ["https://plausible.io"],
          "connect_src" => ["https://plausible.io"]
        },
        user(:admin)
      )

      sources = org_id() |> CodeInjection.for_org() |> CodeInjection.csp_sources()

      assert "https://plausible.io" in sources.script_src
      assert Enum.any?(sources.script_src, &String.starts_with?(&1, "'sha256-"))
      assert sources.connect_src == ["https://plausible.io"]
    end

    test "a save busts the cache, so the snippet and its policy change together" do
      actor = user(:admin)
      save!(%{"head_html" => "<script>one()</script>"}, actor)
      assert CodeInjection.for_org(org_id()).head_html =~ "one()"

      save!(%{"head_html" => "<script>two()</script>"}, actor)
      injection = CodeInjection.for_org(org_id())

      assert injection.head_html =~ "two()"
      assert injection.script_hashes == [Base.encode64(:crypto.hash(:sha256, "two()"))]
    end

    test "whitespace-only HTML resolves to nothing rather than an empty element" do
      save!(%{"head_html" => "   \n  "}, user(:admin))

      refute CodeInjection.any?(CodeInjection.for_org(org_id()))
    end
  end
end
