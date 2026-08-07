defmodule KilnCMS.Beta.RoundTest do
  @moduledoc """
  Beta-round provisioning: the "Before every round" checklist in
  `docs/beta-testing.md`, done mechanically. See `KilnCMS.Beta`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Beta
  alias KilnCMS.Beta.Round
  alias KilnCMS.CMS

  # Each test gets its own round label so the idempotent-by-email/slug lookups
  # can't collide across the suite (`async: false` shares the sandbox).
  defp label, do: "t#{System.unique_integer([:positive])}"

  defp user(email), do: Accounts.get_user_by_email!(email, authorize?: false)

  defp seed_token(account) do
    Ash.Seed.seed!(Accounts.Token, %{
      jti: "jti-#{System.unique_integer([:positive])}",
      subject: AshAuthentication.user_to_subject(account),
      purpose: "user",
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
  end

  defp tenant, do: Accounts.default_org_id()

  defp post_by_slug(slug),
    do: CMS.list_posts!(query: [filter: [slug: slug]], authorize?: false, tenant: tenant())

  defp page_by_slug(slug),
    do: CMS.list_pages!(query: [filter: [slug: slug]], authorize?: false, tenant: tenant())

  describe "seats" do
    test "an authoring round gets editor testers plus one admin facilitator" do
      round = label()

      summary = Round.run(round: round, testers: 2, seed?: false)

      assert summary.shape == :authoring
      assert length(summary.seats) == 3
      assert length(summary.testers) == 2
      assert Enum.all?(summary.testers, &(&1.role == :editor))

      facilitator = Enum.find(summary.seats, & &1.facilitator?)
      assert facilitator.role == :admin
      assert facilitator.email == "beta-facilitator@beta.kiln.test"

      # The seats are real, pre-confirmed accounts at the right tier.
      for seat <- summary.seats do
        account = user(seat.email)
        assert account.role == seat.role
        assert account.confirmed_at != nil
      end
    end

    test "an operator round is admin-tiered throughout, with no separate facilitator" do
      round = label()

      summary = Round.run(shape: :operator, round: round, testers: 2, seed?: false)

      assert summary.shape == :operator
      assert length(summary.seats) == 2
      assert Enum.all?(summary.seats, &(&1.role == :admin))
      refute Enum.any?(summary.seats, & &1.facilitator?)
    end

    test "the shape may be given as a string, as the Mix task passes it" do
      assert Round.run(shape: "operator", round: label(), testers: 1, seed?: false).shape ==
               :operator
    end

    test "an unsupplied facilitator email falls back to the default rather than nil" do
      # The Mix task passes `facilitator_email:` through unconditionally, so the
      # absent case arrives as an explicit nil — which a `Keyword.get/3` default
      # would happily hand straight to the seat.
      summary = Round.run(round: label(), testers: 1, seed?: false, facilitator_email: nil)

      assert Enum.find(summary.seats, & &1.facilitator?).email ==
               "beta-facilitator@beta.kiln.test"
    end

    test "explicit tester emails replace the generated ones" do
      emails = ["a-#{label()}@example.test", "b-#{label()}@example.test"]

      summary = Round.run(round: label(), emails: emails, seed?: false)

      assert Enum.map(summary.testers, & &1.email) == emails
    end

    test "duplicate tester emails are refused rather than silently collapsing" do
      email = "dupe-#{label()}@example.test"

      assert_raise ArgumentError, ~r/duplicate tester emails/, fn ->
        Round.run(round: label(), emails: [email, email], seed?: false)
      end
    end

    test "a facilitator email that is also a tester email is refused" do
      # One account can't hold both seats: the tester pass would demote the
      # publisher to :editor, and the first publish then fails Forbidden — after
      # the accounts already exist.
      email = "both-#{label()}@example.test"

      assert_raise ArgumentError, ~r/can't hold both seats/, fn ->
        Round.run(round: label(), emails: [email], facilitator_email: email, seed?: false)
      end
    end

    test "whitespace-only tester emails are refused, not silently dropped" do
      # The empty-list check has to come *after* trimming, or this provisions a
      # facilitator, zero testers, and reports success.
      assert_raise ArgumentError, ~r/no tester emails given/, fn ->
        Round.run(round: label(), emails: ["   ", ""], seed?: false)
      end
    end

    test "the tester count is bounded" do
      assert_raise ArgumentError, ~r/between 1 and 12/, fn ->
        Round.run(round: label(), testers: 40, seed?: false)
      end

      assert_raise ArgumentError, ~r/between 1 and 12/, fn ->
        Round.run(round: label(), testers: 0, seed?: false)
      end
    end
  end

  describe "re-running a round" do
    test "adds the missing seat without re-issuing passwords for the ones in session" do
      round = label()

      first = Round.run(round: round, testers: 1, seed?: false)
      [tester] = first.testers
      assert tester.password
      hash_before = user(tester.email).hashed_password

      second = Round.run(round: round, testers: 2, seed?: false)

      # The seat that already existed reports no password (it isn't
      # recoverable) and keeps the credential its tester is holding.
      existing = Enum.find(second.testers, &(&1.email == tester.email))
      assert existing.password == nil
      refute existing.created?
      assert user(tester.email).hashed_password == hash_before

      # The new one is created and does get a password to hand out.
      added = Enum.find(second.testers, &(&1.email != tester.email))
      assert added.created?
      assert added.password
    end

    test "--reset-passwords re-issues a lost credential" do
      round = label()
      [tester] = Round.run(round: round, testers: 1, seed?: false).testers
      hash_before = user(tester.email).hashed_password

      reset = Round.run(round: round, testers: 1, seed?: false, reset_passwords?: true)

      assert [%{password: password}] = reset.testers
      assert password
      assert user(tester.email).hashed_password != hash_before
    end

    test "--reset-passwords actually revokes the old credential's sessions" do
      # The reason to reset is that the old password leaked, so the tokens
      # minted under it have to die too. `Ash.Seed.update!` writes the hash
      # without running an action, which skips the `log_out_everywhere` add-on
      # that `apply_on_password_change?` hangs off — leaving a 30-day
      # remember-me token authorizing under a password nobody thinks works.
      round = label()
      [tester] = Round.run(round: round, testers: 1, seed?: false).testers
      account = user(tester.email)

      token = seed_token(account)
      KilnCMSWeb.Endpoint.subscribe(SessionEviction.topic(account.id))

      Round.run(round: round, testers: 1, seed?: false, reset_passwords?: true)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 1_000

      # `log_out_everywhere` flips every stored token for the subject to the
      # `"revocation"` purpose (AshAuthentication's
      # `RevokeAllStoredForSubjectChange`), which is what makes the old JWT stop
      # authenticating under `require_token_presence_for_authentication?`.
      assert Ash.get!(Accounts.Token, %{jti: token.jti}, authorize?: false).purpose ==
               "revocation"
    end

    test "a seat sitting at the wrong tier is corrected, and reported as adopted" do
      round = label()
      [tester] = Round.run(round: round, testers: 1, seed?: false).testers

      # Same email, operator shape: the seat must move to :admin, or the round
      # produces spurious 'I can't reach that page' findings.
      summary = Round.run(shape: :operator, round: round, emails: [tester.email], seed?: false)

      assert [%{role: :admin, adopted_from: :editor}] = summary.testers
      assert user(tester.email).role == :admin
    end

    test "an adopted account's role change goes through :manage_access, not a raw seed" do
      # `Ash.Seed.update!` writes the row without running the action, so it
      # skips `EvictSessions` — and a socket authorizes once, at connect (#675).
      # Assert on the eviction broadcast rather than on the row, because the row
      # looks identical either way.
      round = label()
      [tester] = Round.run(round: round, testers: 1, seed?: false).testers
      id = user(tester.email).id

      KilnCMSWeb.Endpoint.subscribe(SessionEviction.topic(id))

      Round.run(shape: :operator, round: round, emails: [tester.email], seed?: false)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 1_000
    end

    test "seeded content is not duplicated" do
      round = label()

      first = Round.run(round: round, testers: 1)
      assert first.seeded == 2

      second = Round.run(round: round, testers: 1)
      assert second.seeded == 0
    end
  end

  # Mirrors `Round.handle_for/1` — the whole address, not the local part.
  defp handle(email), do: email |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  describe "seed content" do
    test "each tester gets a published post they authored" do
      round = label()
      [tester] = Round.run(round: round, testers: 1).testers

      assert [post] = post_by_slug("beta-r#{round}-#{handle(tester.email)}-post")
      assert post.state == :published
      assert post.author_id == user(tester.email).id
    end

    test "testers sharing an email local part each get their own content" do
      # `alice@acme.test` and `alice@globex.test` are one handle if only the
      # local part is used — and the collision is silent: the second tester's
      # existence check finds the first's record and seeds nothing, so they
      # arrive at the session with the empty CMS this whole step prevents.
      round = label()
      local = "alice-#{label()}"
      emails = ["#{local}@acme.test", "#{local}@globex.test"]

      summary = Round.run(round: round, emails: emails)

      assert summary.seeded == 4

      for email <- emails do
        assert [post] = post_by_slug("beta-r#{round}-#{handle(email)}-post")
        assert post.author_id == user(email).id
      end
    end

    test "each tester gets a draft page with history to restore from" do
      round = label()
      [tester] = Round.run(round: round, testers: 1).testers

      assert [page] = page_by_slug("beta-r#{round}-#{handle(tester.email)}-page")
      assert page.state == :draft
      assert page.author_id == user(tester.email).id

      # `restore_version` is one of the few workflow actions an editor may run,
      # and it needs somewhere to restore *to*.
      versions =
        CMS.list_page_versions!(
          authorize?: false,
          query: [filter: [version_source_id: page.id]]
        )

      assert length(versions) >= 2
    end

    test "--no-seed leaves the CMS empty" do
      round = label()
      [tester] = Round.run(round: round, testers: 1, seed?: false).testers

      assert post_by_slug("beta-r#{round}-#{handle(tester.email)}-post") == []
      assert page_by_slug("beta-r#{round}-#{handle(tester.email)}-page") == []
    end

    test "a trashed seed record still counts as seeded, so a re-run doesn't collide" do
      # The script tells testers to delete a draft and recover it from trash.
      # AshArchival hides the soft-deleted row from the primary read, but the
      # `unique_slug` identity is not partial — it still owns the slug. A re-run
      # that consulted only the live read would try to create and die on the
      # constraint, mid-round.
      round = label()
      summary = Round.run(round: round, testers: 1)
      [tester] = summary.testers
      facilitator = Enum.find(summary.seats, & &1.facilitator?)
      [page] = page_by_slug("beta-r#{round}-#{handle(tester.email)}-page")

      # Trashing is admin-only, so it's the facilitator doing it — which is
      # exactly who runs the trash/restore step of the operator script.
      CMS.destroy_page!(page, actor: user(facilitator.email), tenant: tenant())
      assert page_by_slug("beta-r#{round}-#{handle(tester.email)}-page") == []

      assert Round.run(round: round, testers: 1).seeded == 0
    end
  end

  describe "readiness" do
    test "reports the frozen commit, media storage and the preview template" do
      summary = Round.run(round: label(), testers: 1, seed?: false)

      labels = Enum.map(summary.readiness, fn {label, _status, _detail} -> label end)
      assert "frozen commit" in labels
      assert "media storage" in labels
      assert "presentation preview" in labels
    end

    test "local disk storage is flagged, because uploads don't survive a restart" do
      summary = Round.run(round: label(), testers: 1, seed?: false)

      assert {"media storage", :warn, detail} =
               Enum.find(summary.readiness, &(elem(&1, 0) == "media storage"))

      assert detail =~ "local disk"
    end

    test "an operator round doesn't warn about a preview URL its script never uses" do
      summary = Round.run(shape: :operator, round: label(), testers: 1, seed?: false)

      assert {"presentation preview", :ok, _} =
               Enum.find(summary.readiness, &(elem(&1, 0) == "presentation preview"))
    end
  end

  describe "KilnCMS.Beta.provision!/1" do
    test "refuses without explicit confirmation, and creates nothing" do
      round = label()

      assert_raise RuntimeError, ~r/without explicit confirmation/, fn ->
        Beta.provision!(round: round, testers: 1, shell: fn _ -> :ok end)
      end

      assert {:ok, nil} =
               Accounts.get_user_by_email("beta-r#{round}-t1@beta.kiln.test",
                 not_found_error?: false,
                 authorize?: false
               )
    end

    test "the target-name guard accepts beta-ish databases and refuses production" do
      # The guard the confirmation sits behind: a mistyped DATABASE_URL must not
      # be able to mint known-password accounts. Exercised directly because the
      # suite's own database always satisfies it.
      assert Beta.acceptable_target?("kiln_beta")
      assert Beta.acceptable_target?("kiln_cms_staging")
      assert Beta.acceptable_target?("KILN_CMS_TEST")

      refute Beta.acceptable_target?("kiln_prod")
      refute Beta.acceptable_target?("kiln_cms")
      refute Beta.acceptable_target?("?")

      # A marker has to be a word. A bare substring test lets `latest` through
      # on `test` and `devices` through on `dev` — and this guard is widest
      # exactly where being wrong is worst.
      refute Beta.acceptable_target?("kiln_latest")
      refute Beta.acceptable_target?("devices_live")
      refute Beta.acceptable_target?("contest_results")
    end

    test "with confirmation it provisions and reports the handout" do
      round = label()
      {:ok, agent} = Agent.start_link(fn -> [] end)

      summary =
        Beta.provision!(
          confirm?: true,
          force?: true,
          round: round,
          testers: 1,
          seed?: false,
          shell: fn message -> Agent.update(agent, &[message | &1]) end
        )

      output = agent |> Agent.get(&Enum.reverse/1) |> Enum.join("\n")

      assert length(summary.testers) == 1
      assert output =~ "beta-r#{round}-t1@beta.kiln.test"
      assert output =~ "Readiness"
      assert output =~ "gh label create beta"
    end

    test "the handout is printed before seeding, so a failed seed can't strand a credential" do
      # A generated password exists only in the seats map — `Ash.Seed.seed!`
      # stores the bcrypt hash. Printing it after seeding meant any raise in
      # seeding left live accounts nobody could sign in to.
      {:ok, agent} = Agent.start_link(fn -> [] end)
      round = label()

      assert_raise RuntimeError, "seeding blew up", fn ->
        Beta.provision!(
          confirm?: true,
          force?: true,
          round: round,
          testers: 1,
          # Seeding runs after `:on_seats`, so raising here proves the ordering.
          seed?: true,
          emails: ["boom-#{round}@example.test"],
          shell: fn message ->
            Agent.update(agent, &[message | &1])
            if message =~ "Passwords are shown once", do: raise("seeding blew up")
          end
        )
      end

      output = agent |> Agent.get(&Enum.reverse/1) |> Enum.join("\n")
      assert output =~ "boom-#{round}@example.test"
      # The password column is populated, not the "(unchanged …)" placeholder.
      refute output =~ "(unchanged"
    end

    test "adopting an existing account is called out in the handout" do
      round = label()
      email = "adopt-#{round}@example.test"
      Round.run(round: round, emails: [email], seed?: false)

      {:ok, agent} = Agent.start_link(fn -> [] end)

      Beta.provision!(
        confirm?: true,
        force?: true,
        shape: :operator,
        round: round,
        emails: [email],
        seed?: false,
        shell: fn message -> Agent.update(agent, &[message | &1]) end
      )

      output = agent |> Agent.get(&Enum.reverse/1) |> Enum.join("\n")
      assert output =~ "Re-tiered 1 EXISTING account(s)"
      assert output =~ "editor → admin"
    end
  end

  describe "frozen_commit/0" do
    test "reports a sha, or :unknown outside a git checkout" do
      case Beta.frozen_commit() do
        {sha, dirty?} ->
          assert sha =~ ~r/^[0-9a-f]{7,}$/
          assert is_boolean(dirty?)

        :unknown ->
          # Running outside a git checkout is a legitimate outcome, not a
          # failure — the report says so rather than raising.
          :ok
      end
    end

    test "a dirty tree is reported as a warning, not silently accepted" do
      # Asserted on the interpretation rather than on `frozen_commit/0` itself:
      # whether the suite's own working tree is dirty is not something a test
      # may depend on, and `dirty?` is the load-bearing half — a round frozen
      # against uncommitted changes is not frozen.
      assert {"frozen commit", :ok, "abc1234"} = Round.commit_readiness({"abc1234", false})

      assert {"frozen commit", :warn, detail} = Round.commit_readiness({"abc1234", true})
      assert detail =~ "DIRTY"

      assert {"frozen commit", :warn, _} = Round.commit_readiness(:unknown)
    end
  end
end
