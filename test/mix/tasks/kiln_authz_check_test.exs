defmodule Mix.Tasks.Kiln.Authz.CheckTest do
  @moduledoc """
  The unexplained-policy-bypass gate (#1309).

  A gate that only ever passes proves nothing, so the red cases are asserted
  directly: a bare `authorize?: false`, a comment that is too far away, a
  comment that is near but does not name the bypass, and the ways the scan
  could be fooled into a false pass (the phrase inside a string or a doc).
  The green cases pin the contract a contributor writes to: a trailing
  comment, a comment block above, and the 12-line window.
  """
  # `Mix.shell/1` is process-global state, so the `run/1` cases cannot share
  # the VM with another test that swaps it.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kiln.Authz.Check

  describe "unjustified/2 — red" do
    test "a bare bypass" do
      source = """
      defmodule A do
        def go, do: Ash.read!(Q, authorize?: false)
      end
      """

      assert [{"a.ex", 2}] == Check.unjustified(source, "a.ex")
    end

    test "every bypass in a multi-line keyword list is its own site" do
      source = """
      defmodule A do
        def go do
          CMS.list!(
            authorize?: false,
            tenant: org
          )

          CMS.other!(authorize?: false)
        end
      end
      """

      assert [{"a.ex", 4}, {"a.ex", 8}] == Check.unjustified(source, "a.ex")
    end

    test "a nearby comment that does not name the bypass does not count" do
      source = """
      defmodule A do
        # Loads the roster once at mount so the dropdown never lags.
        def go, do: Ash.read!(Q, authorize?: false)
      end
      """

      assert [{"a.ex", 3}] == Check.unjustified(source, "a.ex")
    end

    test "a justification more than 12 lines above is not adjacent" do
      filler = String.duplicate("    x = 1\n", 11)

      source = """
      defmodule A do
        # `authorize?: false`: system read of display data.
        def go do
      #{filler}    Ash.read!(Q, authorize?: false)
        end
      end
      """

      # comment on line 2, bypass on line 15: 13 apart
      assert [{"a.ex", 15}] == Check.unjustified(source, "a.ex")
    end

    test "a justification BELOW the site does not count" do
      source = """
      defmodule A do
        def go do
          Ash.read!(Q, authorize?: false)
          # `authorize?: false` because this is a system read.
        end
      end
      """

      assert [{"a.ex", 3}] == Check.unjustified(source, "a.ex")
    end

    test "the phrase inside a string or a moduledoc is not a justification" do
      source = ~S'''
      defmodule A do
        @moduledoc """
        Every read here runs `authorize?: false` on purpose.
        """
        def go do
          Logger.info("skipping authorize? check")
          Ash.read!(Q, authorize?: false)
        end
      end
      '''

      assert [{"a.ex", 7}] == Check.unjustified(source, "a.ex")
    end
  end

  describe "unjustified/2 — green" do
    test "a trailing comment on the same line" do
      source = """
      defmodule A do
        def go, do: Ash.read!(Q, authorize?: false) # policy bypass: no actor pre-auth
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "a trailing comment must still name the bypass" do
      source = """
      defmodule A do
        def go, do: Ash.read!(Q, authorize?: false) # system read: no actor here
      end
      """

      assert [{"a.ex", 2}] == Check.unjustified(source, "a.ex")
    end

    test "a comment block above the call, with the bypass several lines down" do
      source = """
      defmodule A do
        # Delivery bypass: `:public_by_slug` filters published + audience itself
        # and `tenant:` scopes it to this site.
        def go do
          CMS.get!(
            slug,
            not_found_error?: false,
            authorize?: false,
            tenant: org
          )
        end
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "exactly 12 lines above still counts" do
      filler = String.duplicate("    x = 1\n", 10)

      source = """
      defmodule A do
        # policy bypass: system read
        def go do
      #{filler}    Ash.read!(Q, authorize?: false)
        end
      end
      """

      # comment on line 2, bypass on line 14: exactly 12 apart
      assert [] == Check.unjustified(source, "a.ex")
    end

    test "the phrase in a comment or a doc alone is not a site" do
      source = ~S'''
      defmodule A do
        @moduledoc """
        Reads carry the actor, not `authorize?: false`.
        """
        # never pass authorize?: false here
        def go, do: Ash.read!(Q, actor: actor)
      end
      '''

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "authorize?: true is not a bypass" do
      source = """
      defmodule A do
        def go, do: Ash.read!(Q, authorize?: true)
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end
  end

  describe "unjustified/2 — one comment serves one site" do
    test "a second bypass pasted under a justified one is red" do
      source = """
      defmodule A do
        def go(conn) do
          # `authorize?: false`: menus are display data; `Menu`'s read policy is
          # `authorize_if always()` regardless; `tenant:` scopes the list.
          menus = CMS.list_menus!(authorize?: false, tenant: org)

          drafts = CMS.list_pages!(authorize?: false, tenant: org)
          users = Accounts.list_users!(authorize?: false)
        end
      end
      """

      assert [{"a.ex", 7}, {"a.ex", 8}] == Check.unjustified(source, "a.ex")
    end

    test "a comment inside another call's span does not reach past it" do
      source = """
      defmodule A do
        def go do
          CMS.get!(
            slug,
            # bypass: delivery filter carries the grant
            authorize?: false,
            tenant: org
          )

          Ash.read!(Q, authorize?: false)
        end
      end
      """

      assert [{"a.ex", 10}] == Check.unjustified(source, "a.ex")
    end

    test "a comment naming something else nearby is not a justification" do
      source = """
      defmodule A do
        def go(conn) do
          # 401 Unauthorized when the header is missing; authorization is
          # checked by the plug above.
          Ash.read!(Q, authorize?: false)
        end
      end
      """

      assert [{"a.ex", 5}] == Check.unjustified(source, "a.ex")
    end
  end

  describe "unjustified/2 — the window is the call, not the option" do
    test "a comment above a call whose bypass is far down its option list" do
      options = for i <- 1..14, do: "      opt#{i}: #{i},\n"

      source = """
      defmodule A do
        # bypass: system read
        def go do
          CMS.list!(
      #{options}      authorize?: false
          )
        end
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "a comment between the options, or on the closing line, counts" do
      source = """
      defmodule A do
        def go do
          CMS.list!(
            authorize?: false,
            # bypass: system read
            tenant: org
          )

          CMS.other!(
            authorize?: false
          ) # bypass: system read
        end
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "two bypass options in one call share its comment" do
      source = """
      defmodule A do
        # bypass: fixture builder
        def go, do: build(authorize?: false, nested: [authorize?: false])
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end
  end

  describe "unjustified/2 — unparsable source" do
    test "raises with the file, line and message rather than crashing" do
      source = """
      defmodule A do
        def go, do: Ash.read!(Q, authorize?: false)
      end
      end
      """

      assert_raise Mix.Error, ~r/a\.ex:4: cannot parse: unexpected reserved word: end/, fn ->
        Check.unjustified(source, "a.ex")
      end
    end
  end

  describe "run/1" do
    @tag :tmp_dir
    test "goes red on an unexplained bypass and names the site", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.ex")

      File.write!(path, """
      defmodule Bad do
        def go, do: Ash.read!(Q, authorize?: false)
      end
      """)

      Mix.shell(Mix.Shell.Process)

      assert_raise Mix.Error, ~r/1 file\(s\) off the authz ratchet/, fn -> Check.run([dir]) end

      # Two error lines: the file's verdict, then the site it is about.
      assert_received {:mix_shell, :error, [verdict]}
      assert verdict =~ "bad.ex: 1 unexplained `authorize?: false`, 0 allowed."
      assert_received {:mix_shell, :error, [site]}
      assert site =~ "bad.ex:2:"
    after
      Mix.shell(Mix.Shell.IO)
    end

    @tag :tmp_dir
    test "passes a justified tree", %{tmp_dir: dir} do
      path = Path.join(dir, "good.ex")

      File.write!(path, """
      defmodule Good do
        # `authorize?: false`: webhook path, no actor exists.
        def go, do: Ash.read!(Q, authorize?: false)
      end
      """)

      Mix.shell(Mix.Shell.Process)
      assert :ok = Check.run([dir])
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "justified"
    after
      Mix.shell(Mix.Shell.IO)
    end

    test "the repo's own tree is on the ratchet" do
      Mix.shell(Mix.Shell.Process)
      assert :ok = Check.run([])
    after
      Mix.shell(Mix.Shell.IO)
    end
  end

  describe "problems/2 — the #1402 ratchet" do
    # `run/1` scans all of `lib/` against a 129-entry backlog, so the ratchet
    # arithmetic is driven here against a two-entry one instead. It is worth
    # pinning directly: wrong in the permissive direction, a ratchet passes
    # forever and nobody finds out.
    @backlog %{"lib/a.ex" => 3}

    test "a file at its allowance, and a clean file, are fine" do
      assert Check.problems(%{"lib/a.ex" => 3, "lib/b.ex" => 0}, @backlog) == []
    end

    test "a backlogged file that gains a site is a regression" do
      assert [message] = Check.problems(%{"lib/a.ex" => 4}, @backlog)
      assert message =~ "lib/a.ex: 4 unexplained"
      assert message =~ "3 allowed by the #1402 backlog"
    end

    test "a file with no entry may have none at all" do
      assert [message] = Check.problems(%{"lib/new.ex" => 1}, @backlog)
      assert message =~ "lib/new.ex: 1 unexplained"
      assert message =~ "0 allowed."
    end

    test "a backlogged file that improves must have its number lowered" do
      assert [message] = Check.problems(%{"lib/a.ex" => 1}, @backlog)
      assert message =~ "allows 3 but the file has 1"
      assert message =~ "lower the number to 1"
    end

    test "a backlogged file that is finished must have its entry dropped" do
      assert [message] = Check.problems(%{"lib/a.ex" => 0}, @backlog)
      assert message =~ "drop the entry"
    end

    test "entries for files the scan did not cover are left alone" do
      # Scanning one file must not report every other backlog entry as stale.
      assert Check.problems(%{"lib/b.ex" => 0}, @backlog) == []
    end
  end

  describe "the real backlog" do
    test "every entry names a file that exists and is positive" do
      # A stale path can never be cleared by the ratchet (nothing scans it), so
      # it would sit there forever looking like outstanding work that is
      # already done. A zero or negative entry would be a no-op allowance.
      for {path, count} <- Check.backlog() do
        assert File.exists?(path), "#{path} is in the #1402 backlog but does not exist"
        assert count > 0, "#{path} has a non-positive backlog entry"
      end
    end

    test "it is the only thing standing between the gate and all of lib/" do
      # Guards the guard: if the backlog were empty the ratchet tests above
      # would still pass while the real gate checked nothing new.
      assert map_size(Check.backlog()) > 0
    end
  end
end
