defmodule Mix.Tasks.Kiln.Authz.CheckTest do
  @moduledoc """
  The unexplained-policy-bypass gate (#1309, #1739).

  A gate that only ever passes proves nothing, so the red cases are asserted
  directly — above all the ones #1739 was about: prose that merely mentions
  "bypass" (`multitenancy :bypass`, "the admin bypass above"), a marker with no
  reason, and a marker reaching down to a second call. The green cases pin the
  contract a contributor writes to: `# authorize?: false — <reason>` directly
  above the call, or inside it.
  """
  # `Mix.shell/1` is process-global state, so the `run/1` cases cannot share
  # the VM with another test that swaps it.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kiln.Authz.Check

  describe "marker?/1 — the grammar" do
    test "an em dash or `--`, then a reason of at least three words" do
      assert Check.marker?("# authorize?: false — webhook path, no actor")
      assert Check.marker?("# authorize?: false -- webhook path, no actor")
      assert Check.marker?("#authorize?: false — webhook path, no actor")
    end

    test "an empty or too-short reason is not one" do
      refute Check.marker?("# authorize?: false —")
      refute Check.marker?("# authorize?: false — ")
      refute Check.marker?("# authorize?: false — see above")
      refute Check.marker?("# authorize?: false — see `claim/4`.")
      refute Check.marker?("# authorize?: false — ... --- !!!")
    end

    test "prose that mentions the bypass is not one" do
      refute Check.marker?("# policy bypass: webhook path, no actor here")
      refute Check.marker?("# `authorize?: false`: webhook path, no actor here")
      refute Check.marker?("# Stays `authorize?: false` (#1659): a content read")
      refute Check.marker?("# multitenancy :bypass — the token is the only filter")
      refute Check.marker?("# authorize?: false webhook path, no actor here")
      refute Check.marker?("# authorize?: false: webhook path, no actor here")
      refute Check.marker?("# authorize?: true — webhook path, no actor here")
    end
  end

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

    test "unrelated prose mentioning a bypass does not justify it (#1739)" do
      source = """
      defmodule A do
        def go do
          # The admin bypass above already let this caller in, so authorize?
          # is not checked twice.
          Ash.read!(Q, authorize?: false)
        end
      end
      """

      assert [{"a.ex", 5}] == Check.unjustified(source, "a.ex")
    end

    test "a `multitenancy :bypass` comment does not justify it (#1739)" do
      source = """
      defmodule A do
        # `:by_token` is a `multitenancy :bypass` read.
        def go(token), do: Ash.read!(Q, token: token, authorize?: false)
      end
      """

      assert [{"a.ex", 3}] == Check.unjustified(source, "a.ex")
    end

    test "the old `# `authorize?: false`: reason` form no longer counts" do
      source = """
      defmodule A do
        # `authorize?: false`: system read of display data.
        def go, do: Ash.read!(Q, authorize?: false)
      end
      """

      assert [{"a.ex", 3}] == Check.unjustified(source, "a.ex")
    end

    test "a marker with an empty or token reason does not count" do
      for reason <- ["", " ", " see above", " see `claim/4`."] do
        source = """
        defmodule A do
          # authorize?: false —#{reason}
          def go, do: Ash.read!(Q, authorize?: false)
        end
        """

        assert [{"a.ex", 3}] == Check.unjustified(source, "a.ex"), inspect(reason)
      end
    end

    test "a marker above the enclosing `def` does not reach into its body" do
      source = """
      defmodule A do
        # authorize?: false — webhook path, no actor exists
        def go do
          x = 1
          Ash.read!(Q, authorize?: false)
        end
      end
      """

      assert [{"a.ex", 5}] == Check.unjustified(source, "a.ex")
    end

    test "a blank line between the marker and the call breaks it" do
      source = """
      defmodule A do
        def go do
          # authorize?: false — webhook path, no actor exists

          Ash.read!(Q, authorize?: false)
        end
      end
      """

      assert [{"a.ex", 5}] == Check.unjustified(source, "a.ex")
    end

    test "a marker BELOW the site does not count" do
      source = """
      defmodule A do
        def go do
          Ash.read!(Q, authorize?: false)
          # authorize?: false — webhook path, no actor exists
        end
      end
      """

      assert [{"a.ex", 3}] == Check.unjustified(source, "a.ex")
    end

    test "the marker inside a string or a moduledoc is not a justification" do
      source = ~S'''
      defmodule A do
        @moduledoc """
        # authorize?: false — every read here is a system read
        """
        def go do
          Logger.info("# authorize?: false — skipping the check here")
          Ash.read!(Q, authorize?: false)
        end
      end
      '''

      assert [{"a.ex", 7}] == Check.unjustified(source, "a.ex")
    end
  end

  describe "unjustified/2 — green" do
    test "a marker directly above the call" do
      source = """
      defmodule A do
        def go do
          # authorize?: false — webhook path, no actor exists
          Ash.read!(Q, authorize?: false)
        end
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "`--` for the dash" do
      source = """
      defmodule A do
        def go do
          # authorize?: false -- webhook path, no actor exists
          Ash.read!(Q, authorize?: false)
        end
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "anywhere in the comment block directly above, with the reason running on" do
      source = """
      defmodule A do
        def go do
          # Loads the roster once at mount so the dropdown never lags.
          #
          # authorize?: false — delivery: `:public_by_slug` filters published +
          # audience itself, and `tenant:` scopes it to this site.
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

    test "a trailing marker on the same line" do
      source = """
      defmodule A do
        def go, do: Ash.read!(Q, authorize?: false) # authorize?: false — pre-auth, no actor yet
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "a trailing comment must still be a marker" do
      source = """
      defmodule A do
        def go, do: Ash.read!(Q, authorize?: false) # policy bypass: no actor pre-auth
      end
      """

      assert [{"a.ex", 2}] == Check.unjustified(source, "a.ex")
    end

    test "above a one-line `def ..., do:` the call is part of" do
      source = """
      defmodule A do
        # authorize?: false — webhook path, no actor exists
        def go,
          do: Ash.read!(Q, authorize?: false)
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "above the head of a pipeline, or of the match it is bound in" do
      source = """
      defmodule A do
        def go do
          # authorize?: false — webhook path, no actor exists
          Q
          |> Ash.Query.filter(x == 1)
          |> Ash.read!(authorize?: false)

          # authorize?: false — webhook path, no actor exists
          {:ok, row} =
            Q
            |> Ash.read_one(authorize?: false)

          row
        end
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "above a `with` clause, a `case` clause's pattern, or an `fn` it is passed in" do
      source = """
      defmodule A do
        def go do
          with {:ok, a} <- a(),
               # authorize?: false — webhook path, no actor exists
               {:ok, b} <-
                 Ash.read_one(Q, authorize?: false) do
            case a do
              # authorize?: false — webhook path, no actor exists
              :x ->
                Ash.read!(Q, authorize?: false)
            end

            # authorize?: false — webhook path, no actor exists
            fetch = fn loc ->
              Ash.read!(Q, locale: loc, authorize?: false)
            end
          end
        end
      end
      """

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

  describe "unjustified/2 — one marker serves one site" do
    test "a second bypass pasted under a justified one is red (#1739)" do
      source = """
      defmodule A do
        def go(conn) do
          # authorize?: false — menus are display data; `Menu`'s read policy is
          # `authorize_if always()` regardless; `tenant:` scopes the list.
          menus = CMS.list_menus!(authorize?: false, tenant: org)
          drafts = CMS.list_pages!(authorize?: false, tenant: org)
          users = Accounts.list_users!(authorize?: false)
        end
      end
      """

      assert [{"a.ex", 6}, {"a.ex", 7}] == Check.unjustified(source, "a.ex")
    end

    test "two bypass calls in one statement need two markers" do
      source = """
      defmodule A do
        def go do
          # authorize?: false — webhook path, no actor exists
          Q
          |> Ash.read!(authorize?: false)
          |> Ash.load!(:author, authorize?: false)
        end
      end
      """

      assert [{"a.ex", 6}] == Check.unjustified(source, "a.ex")
    end

    test "each of two markers takes its own call" do
      source = """
      defmodule A do
        def go do
          # authorize?: false — webhook path, no actor exists
          Q
          |> Ash.read!(authorize?: false)
          # authorize?: false — display data, the author's name only
          |> Ash.load!(:author, authorize?: false)
        end
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "a marker inside another call's span does not reach past it" do
      source = """
      defmodule A do
        def go do
          CMS.get!(
            slug,
            # authorize?: false — delivery filter carries the grant
            authorize?: false,
            tenant: org
          )

          Ash.read!(Q, authorize?: false)
        end
      end
      """

      assert [{"a.ex", 10}] == Check.unjustified(source, "a.ex")
    end
  end

  describe "unjustified/2 — the call is the site, not the option" do
    test "a marker above a call whose bypass is far down its option list" do
      options = for i <- 1..14, do: "        opt#{i}: #{i},\n"

      source = """
      defmodule A do
        def go do
          # authorize?: false — webhook path, no actor exists
          CMS.list!(
      #{options}        authorize?: false
          )
        end
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "a marker between the options, or on the closing line, counts" do
      source = """
      defmodule A do
        def go do
          CMS.list!(
            authorize?: false,
            # authorize?: false — webhook path, no actor exists
            tenant: org
          )

          CMS.other!(
            authorize?: false
          ) # authorize?: false — webhook path, no actor exists
        end
      end
      """

      assert [] == Check.unjustified(source, "a.ex")
    end

    test "two bypass options in one call share its marker" do
      source = """
      defmodule A do
        # authorize?: false — a fixture builder, never on a request path
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
        # authorize?: false — webhook path, no actor exists.
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
    # `run/1` scans all of `lib/` against the real (now empty) backlog, so the ratchet
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

    test "it is empty: every file under lib/ is held to zero (#1659)" do
      # The migration finished. An entry added back would be an exemption, and
      # "no entry may be added" is the rule; this pins it.
      assert Check.backlog() == %{}
    end

    test "with the backlog empty, one unexplained site anywhere fails the scan" do
      # Guards the guard: an empty backlog must mean "nothing allowed", not
      # "nothing checked".
      assert [message] = Check.problems(%{"lib/anywhere.ex" => 1})
      assert message =~ "lib/anywhere.ex: 1 unexplained"
      assert message =~ "0 allowed."
    end
  end
end
