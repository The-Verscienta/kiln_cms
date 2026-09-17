defmodule KilnCMS.Portability.CLITest do
  @moduledoc """
  The shared operator-facing edges of the portability tasks (#487): who a run
  acts as, and what its report says.

  Both are things an operator acts on without a second source to check them
  against — content attributed to the printed actor, a dry run believed to be
  one — so the tests pin the printed text, not only the returned value.
  """
  # async: false — `Mix.shell/1` is a VM-global setting.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.OrgFixtures
  alias KilnCMS.Portability.CLI
  alias KilnCMS.Portability.Import
  alias KilnCMS.Portability.WXR
  alias KilnCMS.WXRFixture

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  defp user(role, email \\ nil) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email || "cli-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # Everything the shell was told, in order, as one string.
  defp output do
    collect([]) |> Enum.reverse() |> Enum.join("\n")
  end

  defp collect(acc) do
    receive do
      {:mix_shell, :info, [line]} -> collect([line | acc])
    after
      0 -> acc
    end
  end

  describe "scope!/1" do
    test "--actor and --org resolve to that user and that organization's id" do
      editor = user(:editor)
      org = OrgFixtures.org("cli-scope")

      assert [actor: actor, tenant: tenant] = CLI.scope!(actor: editor.email, org: org.slug)
      assert actor.id == editor.id
      assert tenant == org.id
      assert output() =~ "Acting as #{editor.email} in org #{org.id}"
    end

    test "with neither, an admin in the default organization" do
      admin = user(:admin)
      _editor = user(:editor)

      assert [actor: actor, tenant: tenant] = CLI.scope!([])
      assert actor.role == :admin
      assert tenant == KilnCMS.Accounts.default_org_id()
      # Only one admin exists, so "an admin" is this one — and the line printed
      # names the user the run will actually be attributed to.
      assert actor.id == admin.id
      assert output() =~ "Acting as #{admin.email} in org #{tenant}"
    end

    test "no admin and no --actor refuses, rather than running as nobody" do
      _editor = user(:editor)

      assert_raise Mix.Error, ~r/No admin user to run as/, fn -> CLI.scope!([]) end
    end

    test "an --actor that matches no user refuses, rather than falling back to an admin" do
      _admin = user(:admin)

      assert_raise Mix.Error, "No user with email nobody@example.com", fn ->
        CLI.scope!(actor: "nobody@example.com")
      end

      # Nothing printed: an "Acting as" line before the refusal would name an
      # actor the run never used.
      refute output() =~ "Acting as"
    end

    test "an --org that matches no organization refuses, rather than using the default" do
      admin = user(:admin)

      assert_raise Mix.Error, "No organization with slug nowhere", fn ->
        CLI.scope!(actor: admin.email, org: "nowhere")
      end
    end
  end

  describe "author_map!/1" do
    test "trims each side, and keeps an = inside the email part" do
      assert CLI.author_map!([" jo = jo@x.com ", "odd=a=b@x.com"]) ==
               %{"jo" => "jo@x.com", "odd" => "a=b@x.com"}
    end

    test "no flags is an empty map" do
      assert CLI.author_map!([]) == %{}
    end

    test "an empty email side is refused, naming the value" do
      assert_raise Mix.Error, ~s(--author-map expects login=email, got: "jo="), fn ->
        CLI.author_map!(["jo="])
      end
    end
  end

  describe "print_report/1 — from a real import" do
    setup do
      actor = user(:admin)
      {:ok, parsed} = WXR.parse(WXRFixture.wxr())
      %{actor: actor, parsed: parsed}
    end

    test "a dry run says so first and last, in the future tense", %{actor: actor, parsed: parsed} do
      {:ok, report} = Import.run(parsed, actor: actor, dry_run: true)

      assert :ok = CLI.print_report(report)
      out = output()

      assert out =~ ~r/\A── DRY RUN — nothing was written/
      assert out =~ ~r/── DRY RUN — re-run without --dry-run to apply ─+\z/u
      assert out =~ "Records:   3 would be created, 0 skipped (already present), 0 failed"
      assert out =~ "Media:     1 would be imported"
      assert out =~ ~r/Redirects: \d+ would be created/
    end

    test "a real run has no dry-run banner and speaks in the past tense", %{
      actor: actor,
      parsed: parsed
    } do
      {:ok, report} = Import.run(parsed, actor: actor, skip_media: true)

      CLI.print_report(report)
      out = output()

      refute out =~ "DRY RUN"
      assert out =~ "Records:   3 created, 0 skipped (already present), 0 failed"
      assert out =~ ~r/Taxonomy:  \d+ new \/ \d+ matched categories, \d+ new \/ \d+ matched tags/
      assert out =~ "Media:     1 skipped (--skip-media)"
      refute out =~ "would be"
    end

    test "a re-run reports what was already present as skipped", %{actor: actor, parsed: parsed} do
      {:ok, _first} = Import.run(parsed, actor: actor, skip_media: true)
      {:ok, second} = Import.run(parsed, actor: actor, skip_media: true)

      CLI.print_report(second)

      assert output() =~ "Records:   0 created, 3 skipped (already present), 0 failed"
    end

    test "an author who resolved to no Kiln user is listed with the --author-map hint", %{
      actor: actor,
      parsed: parsed
    } do
      {:ok, report} = Import.run(parsed, actor: actor, dry_run: true)

      CLI.print_report(report)
      out = output()

      assert out =~ "Authors (0 mapped, 1 unmapped):"
      assert out =~ ~s(   ~ jo "Jo Example" <jo@old.example.com>)
      assert out =~ "Map them with --author-map login=kiln@email (repeatable)."
    end

    test "a mapped author is marked as such, and the hint is gone", %{
      actor: actor,
      parsed: parsed
    } do
      {:ok, report} =
        Import.run(parsed, actor: actor, dry_run: true, author_map: %{"jo" => actor.email})

      CLI.print_report(report)
      out = output()

      assert out =~ "Authors (1 mapped, 0 unmapped):"
      assert out =~ ~s(  -> jo "Jo Example" <jo@old.example.com>)
      refute out =~ "--author-map"
    end
  end

  describe "print_report/1 — the sections a real fixture does not reach" do
    defp report(overrides) do
      Map.merge(
        %{
          dry_run: false,
          created: [],
          skipped: [],
          failed: [],
          taxonomy: %{categories: %{matched: 0, created: 0}, tags: %{matched: 0, created: 0}},
          media: %{imported: 0, failed: []},
          redirects: %{created: 0}
        },
        overrides
      )
    end

    test "failed records are listed with their reason, capped at 20 with the remainder counted" do
      failed = for n <- 1..23, do: %{kind: :post, title: "Post #{n}", reason: "slug taken"}

      CLI.print_report(report(%{failed: failed}))
      out = output()

      # The summary count is the complete number, never the truncated one.
      assert out =~ "0 skipped (already present), 23 failed"
      assert out =~ "\nFailed (23):"
      assert out =~ ~s(  post "Post 1": slug taken)
      assert out =~ ~s(  post "Post 20": slug taken)
      refute out =~ ~s("Post 21")
      assert out =~ "  … and 3 more"
    end

    test "exactly 20 failures are all listed, with no remainder line" do
      failed = for n <- 1..20, do: %{kind: :page, title: "Page #{n}", reason: "x"}

      CLI.print_report(report(%{failed: failed}))
      out = output()

      assert out =~ ~s("Page 20")
      refute out =~ "more"
    end

    test "media that could not be fetched is listed by URL" do
      failures = [%{url: "https://old.example.com/a.png", reason: {:http_status, 404}}]

      CLI.print_report(report(%{media: %{imported: 2, failed: failures}}))
      out = output()

      assert out =~ "Media:     2 imported, 1 failed"
      assert out =~ "\nMedia that could not be fetched (1):"
      assert out =~ "  https://old.example.com/a.png: {:http_status, 404}"
    end

    test "an envelope report — no authors, no redirect count — still prints" do
      report = report(%{redirects: %{}}) |> Map.delete(:authors)

      assert :ok = CLI.print_report(report)
      out = output()

      assert out =~ "Redirects: 0 created"
      refute out =~ "Authors"
      refute out =~ "Failed"
    end

    test "an author list with nobody in it prints no Authors section" do
      CLI.print_report(report(%{authors: %{found: [], mapped: [], unmapped: []}}))

      refute output() =~ "Authors"
    end
  end

  describe "maybe_drain_media/1" do
    test "true runs the media queue before returning, and says what ran" do
      assert :ok = CLI.maybe_drain_media(true)
      out = output()

      assert out =~ "Draining the media queue"
      assert out =~ ~r/Media jobs: %\{.*success: \d+/
    end

    test "anything else leaves the queue alone and prints nothing" do
      for value <- [nil, false] do
        assert :ok = CLI.maybe_drain_media(value)
      end

      assert output() == ""
    end
  end
end
