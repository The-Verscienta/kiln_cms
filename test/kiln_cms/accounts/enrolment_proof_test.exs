defmodule KilnCMS.Accounts.EnrolmentProofTest do
  @moduledoc """
  `KilnCMS.Accounts.EnrolmentProof` (#2247, owner decision 1b): who is asked
  for the emailed code, the code's delivery, its budget and its binding to the
  account and the session, and when no working relay skips it — only a relay
  retrying will not fix, never a failure that may pass.

  The action-side refusal is `RequireEnrolmentProofTest`; the two budgets
  and the deployment with no mail server, which need `Application.put_env`,
  are `EnrolmentProofEnvTest` below.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.EnrolmentProof
  alias KilnCMS.CMS
  alias KilnCMS.Mail

  @moduletag :capture_log

  @long_ago ~U[2026-01-01 00:00:00.000000Z]

  setup do
    site = org("ep")
    policy!(site, :everyone)
    %{site: site, user: held_viewer(site)}
  end

  def policy!(site, required_for) do
    Ash.Seed.seed!(KilnCMS.CMS.SiteSecondFactorPolicy, %{
      org_id: site.id,
      required_for: required_for,
      grace_days: 0,
      admin_required_since: @long_ago,
      editor_required_since: @long_ago,
      viewer_required_since: @long_ago,
      policy_changed_at: @long_ago
    })

    KilnCMS.Cache.bust_second_factor_policy(site.id)
  end

  def held_viewer(site) do
    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: "ep-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer,
        inserted_at: @long_ago
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: user.id,
      role: :viewer,
      inserted_at: @long_ago
    })

    user
  end

  def session(method \\ "password", jti \\ nil),
    do: %{
      jti: jti || "jti-#{System.unique_integer([:positive])}",
      method: method,
      signed_in_at: DateTime.utc_now()
    }

  def code_in(%Swoosh.Email{html_body: body}) do
    [_, code] = Regex.run(~r/<strong>(\d{6})<\/strong>/, body)
    code
  end

  defp emailed_code do
    assert_email_sent(fn email ->
      send(self(), {:code, code_in(email)})
      true
    end)

    assert_received {:code, code}
    code
  end

  defp relay!(site, attrs \\ %{}) do
    %{
      host: "smtp.example.com",
      port: 587,
      username: "apikey",
      password: "s3cret-pass",
      from_email: "news@site.example"
    }
    |> Map.merge(attrs)
    |> CMS.save_site_mail_relay!(tenant: site, authorize?: false)
  end

  defp force_relay_column!(row, column, value) do
    {1, _} =
      KilnCMS.Repo.update_all(
        Ecto.Query.from(r in "site_mail_relays", where: r.id == type(^row.id, :binary_id)),
        set: [{column, value}]
      )
  end

  describe "decide/4" do
    test "a held password session must prove; other sessions say why not", %{
      site: site,
      user: user
    } do
      assert EnrolmentProof.decide(user, site.id, session("password")) == :required
      assert EnrolmentProof.decide(user, site.id, session("remember_me")) == :required
      assert EnrolmentProof.decide(user, site.id, session("something_new")) == :required
      assert EnrolmentProof.decide(user, site.id, nil) == :required

      assert EnrolmentProof.decide(user, site.id, session("magic_link")) ==
               {:not_needed, "magic_link_session"}

      assert EnrolmentProof.decide(user, site.id, session("sso")) == {:not_needed, "not_required"}
    end

    test "nobody is asked in the grace period, or on a site that holds nobody", %{user: user} do
      grace_site = org("ep-grace")

      Ash.Seed.seed!(KilnCMS.CMS.SiteSecondFactorPolicy, %{
        org_id: grace_site.id,
        required_for: :everyone,
        grace_days: 30,
        viewer_required_since: DateTime.utc_now(),
        policy_changed_at: DateTime.utc_now()
      })

      KilnCMS.Cache.bust_second_factor_policy(grace_site.id)

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        organization_id: grace_site.id,
        user_id: user.id,
        role: :viewer,
        inserted_at: @long_ago
      })

      assert EnrolmentProof.decide(user, grace_site.id, session()) ==
               {:not_needed, "not_required"}

      off_site = org("ep-off")
      assert EnrolmentProof.decide(user, off_site.id, session()) == {:not_needed, "not_required"}
    end
  end

  describe "send_code/3 and verify/4" do
    test "the code is mailed to the account; only its HMAC comes back", %{
      site: site,
      user: user
    } do
      session = session()
      assert {:ok, pending} = EnrolmentProof.send_code(user, site.id, session)
      code = emailed_code()

      refute inspect(pending) =~ code
      assert DateTime.diff(pending.expires_at, DateTime.utc_now()) in 590..600

      assert {:ok, proof} = EnrolmentProof.verify(user, session, code, pending)
      assert {:ok, "email"} = EnrolmentProof.accept(user, site.id, session, proof)
    end

    test "a wrong code, another session's or another account's, and none sent are invalid", %{
      site: site,
      user: user
    } do
      session = session()
      {:ok, pending} = EnrolmentProof.send_code(user, site.id, session)
      code = emailed_code()
      wrong = if code == "000000", do: "000001", else: "000000"

      assert EnrolmentProof.verify(user, session, wrong, pending) == {:error, :invalid}
      assert EnrolmentProof.verify(user, session(), code, pending) == {:error, :invalid}

      assert EnrolmentProof.verify(held_viewer(site), session, code, pending) ==
               {:error, :invalid}

      assert EnrolmentProof.verify(user, session, code, nil) == {:error, :invalid}
    end

    test "an expired code is refused", %{site: site, user: user} do
      session = session()
      {:ok, pending} = EnrolmentProof.send_code(user, site.id, session)
      code = emailed_code()
      expired = %{pending | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}

      assert EnrolmentProof.verify(user, session, code, expired) == {:error, :expired}
    end

    test "a session with no token gets no code", %{site: site, user: user} do
      assert EnrolmentProof.send_code(user, site.id, %{session() | jti: nil}) ==
               {:error, :no_session}

      refute_email_sent()
    end

    test "three codes an hour to an address", %{site: site, user: user} do
      for _ <- 1..3, do: assert({:ok, _} = EnrolmentProof.send_code(user, site.id, session()))
      assert EnrolmentProof.send_code(user, site.id, session()) == {:error, :throttled}
    end

    test "the code never reaches the log", %{site: site, user: user} do
      relay!(site)
      session = session()

      log =
        capture_log(fn ->
          {:ok, pending} = EnrolmentProof.send_code(user, site.id, session)
          assert_received {:site_relay_email, email, _config}
          code = code_in(email)
          send(self(), {:code, code})
          EnrolmentProof.verify(user, session, "999999", pending)
          EnrolmentProof.verify(user, session, code, pending)
        end)

      assert_received {:code, code}
      refute log =~ code
    end
  end

  describe "no working relay" do
    test "a site relay whose password can't be decrypted skips the proof, and says so", %{
      site: site,
      user: user
    } do
      row = relay!(site)
      force_relay_column!(row, :password_encrypted, :crypto.strong_rand_bytes(48))

      refute Mail.relay_available?(site.id)
      assert EnrolmentProof.send_code(user, site.id, session()) == {:skip, :no_relay}

      assert EnrolmentProof.accept(user, site.id, session(), :no_relay) ==
               {:ok, "email_skipped_no_relay"}
    end

    test "a relay that failed this time does not skip it", %{site: site, user: user} do
      # A host that now resolves somewhere private: refused at send, and held
      # by the mail queue for a retry — not a missing relay.
      row = relay!(site)
      force_relay_column!(row, :host, "10.0.0.25")

      assert Mail.relay_available?(site.id)
      assert EnrolmentProof.send_code(user, site.id, session()) == {:error, :send_failed}

      assert EnrolmentProof.accept(user, site.id, session(), :no_relay) ==
               {:error, :proof_required}
    end

    test "only a relay retrying will not fix counts as none" do
      assert Mail.no_relay?(:mailer_not_configured)
      assert Mail.no_relay?({:site_relay, :credentials_unreadable})

      # Settings that could not be read just now are transient (#2247 critic C-2).
      refute Mail.no_relay?({:site_relay, :unavailable})
      refute Mail.no_relay?({:site_relay, {:host_refused, "private address"}})
      refute Mail.no_relay?({:mailer_crashed, "noproc"})

      refute Mail.no_relay?(
               {:retries_exceeded, {:network_failure, ~c"smtp", {:error, :econnrefused}}}
             )
    end

    test "a skip is not accepted while mail works", %{site: site, user: user} do
      assert Mail.relay_available?(site.id)

      assert EnrolmentProof.accept(user, site.id, session(), :no_relay) ==
               {:error, :proof_required}
    end
  end
end

defmodule KilnCMS.Accounts.EnrolmentProofEnvTest do
  @moduledoc """
  `KilnCMS.Accounts.EnrolmentProof` under configuration (#2247): the shared
  second-factor budget at its shipped size, and a deployment with no outgoing
  mail server at all.

  `async: false`: both are `Application.put_env`, a process-wide write.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]
  import Swoosh.TestAssertions

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.EnrolmentProof
  alias KilnCMS.Accounts.EnrolmentProofTest, as: Fixtures
  alias KilnCMS.Mail

  @moduletag :capture_log

  setup do
    site = org("ep-env")
    Fixtures.policy!(site, :everyone)
    %{site: site, user: Fixtures.held_viewer(site)}
  end

  defp put_env(app, key, value) do
    previous = Application.get_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(app, key),
        else: Application.put_env(app, key, previous)
    end)
  end

  test "a wrong code is charged first, and the sixth attempt is refused uncompared", %{
    site: site,
    user: user
  } do
    throttle = Application.get_env(:kiln_cms, AccountThrottle, [])

    put_env(
      :kiln_cms,
      AccountThrottle,
      Keyword.put(
        throttle,
        :second_factor_budget,
        AccountThrottle.defaults()[:second_factor_budget]
      )
    )

    on_exit(fn -> AccountThrottle.forgive_second_factor(user.id) end)

    session = Fixtures.session()
    {:ok, pending} = EnrolmentProof.send_code(user, site.id, session)

    assert_email_sent(fn email -> send(self(), {:code, Fixtures.code_in(email)}) end)
    assert_received {:code, code}

    wrong = if code == "000000", do: "000001", else: "000000"

    for _ <- 1..5,
        do: assert(EnrolmentProof.verify(user, session, wrong, pending) == {:error, :invalid})

    assert {:error, {:throttled, _ms}} = EnrolmentProof.verify(user, session, code, pending)
  end

  test "no outgoing mail server skips the proof", %{site: site, user: user} do
    # What a release ships: the stock local adapter and no mailbox for it.
    put_env(:kiln_cms, KilnCMS.Mailer, adapter: Swoosh.Adapters.Local)
    put_env(:swoosh, :local, false)

    refute Mail.relay_available?(site.id)
    assert EnrolmentProof.send_code(user, site.id, Fixtures.session()) == {:skip, :no_relay}

    assert EnrolmentProof.accept(user, site.id, Fixtures.session(), :no_relay) ==
             {:ok, "email_skipped_no_relay"}
  end
end
