defmodule KilnCMS.Beta.Round do
  @moduledoc """
  The work behind `KilnCMS.Beta.provision!/1`: seats, seed content, readiness.

  > #### Unguarded {: .warning}
  >
  > Nothing here checks which database it is pointed at, and `run/1` will
  > happily mint an `:admin` account against production. Callers are
  > responsible for the safety guards — use `KilnCMS.Beta.provision!/1`.

  Split out for the same reason `KilnCMS.Staging.Scrub` is: the guards and the
  human-facing report belong to the entry point, the data changes belong here,
  and the tests want to reach the data changes without the guards.

  Everything is **idempotent** by natural key (email / slug), so re-running a
  round label mid-round adds the seats that are missing without disturbing the
  ones that are working.
  """

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @type seat :: %{
          email: String.t(),
          role: :editor | :admin,
          password: String.t() | nil,
          facilitator?: boolean(),
          created?: boolean(),
          adopted_from: :editor | :admin | :viewer | nil
        }

  @type seats :: %{
          round: String.t(),
          shape: :authoring | :operator,
          seats: [seat()],
          testers: [seat()]
        }

  @type summary :: %{
          round: String.t(),
          shape: :authoring | :operator,
          seats: [seat()],
          testers: [seat()],
          seeded: non_neg_integer(),
          readiness: [{String.t(), :ok | :warn, String.t()}]
        }

  # docs/beta-testing.md: 4-6 testers per round, "enough to surface the majority
  # of UX issues without drowning triage". The cap is a typo guard, not a limit
  # anyone should be reaching — `--testers 40` is a slipped keystroke.
  @default_testers 4
  @max_testers 12
  @default_domain "beta.kiln.test"

  @doc """
  Provision the round. See `KilnCMS.Beta.provision!/1` for the options.

  `:on_seats` is a 1-arity callback invoked with the `t:seats/0` map as soon as
  the accounts exist and **before** any seeding runs. It is how the handout gets
  printed: a generated password lives only in that map — `Ash.Seed.seed!` stores
  the bcrypt hash and nothing else — so a raise during seeding would otherwise
  leave live accounts whose credentials nobody can recover.
  """
  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    seats = provision_seats(opts)

    case Keyword.get(opts, :on_seats) do
      nil -> :ok
      callback when is_function(callback, 1) -> callback.(seats)
    end

    # Seeding publishes, which is admin-only — so it needs an admin actor. For
    # an operator round the testers *are* admins; for an authoring round it's
    # the facilitator. Either way, resolve it from the seats we just made rather
    # than reaching for "some admin in the database".
    publisher = publisher(seats.seats)

    seeded =
      if Keyword.get(opts, :seed?, true) do
        Enum.sum(Enum.map(seats.testers, &seed_for(&1, seats.round, publisher)))
      else
        0
      end

    seats
    |> Map.put(:seeded, seeded)
    |> Map.put(:readiness, readiness(seats.shape))
  end

  @doc """
  Create (or adopt) the round's accounts, without seeding anything.
  """
  @spec provision_seats(keyword()) :: seats()
  def provision_seats(opts \\ []) do
    shape = shape!(Keyword.get(opts, :shape, :authoring))
    round = to_string(Keyword.get(opts, :round, "1"))
    domain = Keyword.get(opts, :domain, @default_domain)
    reset? = Keyword.get(opts, :reset_passwords?, false)

    # `||`, not a `Keyword.get/3` default: the Mix task passes the key through
    # unconditionally, so an unsupplied `--facilitator-email` arrives as an
    # explicit nil and a default would never be reached.
    facilitator_email = Keyword.get(opts, :facilitator_email) || "beta-facilitator@#{domain}"
    tester_emails = tester_emails!(opts, round, domain)

    # The facilitator seat is the finding this whole task exists to encode:
    # `publish` is admin-only on Page/Post/Entry, so an authoring round whose
    # scenarios end in "publish the post" stalls on step 7 without an admin at
    # the keyboard. An operator round is admin-tiered throughout, so its testers
    # already hold the seat and a separate one would be noise.
    #
    # It is checked against the tester list because one account can't hold two
    # seats: the second `seat/4` overwrites the role the first just set, and the
    # publisher — resolved from the stale seat map — is then an :editor, so the
    # first publish fails Forbidden halfway through the round.
    facilitator =
      if shape == :authoring do
        if facilitator_email in tester_emails do
          raise ArgumentError,
                "the facilitator email #{facilitator_email} is also a tester email — " <>
                  "one account can't hold both seats"
        end

        [seat(facilitator_email, :admin, true, reset?)]
      else
        []
      end

    tester_role = if shape == :authoring, do: :editor, else: :admin
    testers = Enum.map(tester_emails, &seat(&1, tester_role, false, reset?))

    %{round: round, shape: shape, seats: facilitator ++ testers, testers: testers}
  end

  # --- seats ----------------------------------------------------------------

  # Roles can't be set through `register_with_password` (it always defaults to
  # :viewer so self-registration can't escalate) and beta seats must be
  # pre-confirmed, so a *new* seat is created directly — the same reasoning, and
  # the same mechanism, as `priv/repo/seeds.exs`.
  #
  # An *existing* account is a different problem. `--tester` takes real
  # addresses, so it can land on somebody who already has an account here, and
  # changing their role or password through `Ash.Seed.update!` would skip the
  # two things that make those changes safe: `:manage_access`'s
  # `EvictSessions` (a socket authorizes once, at connect — #675) and the
  # `log_out_everywhere` add-on that `apply_on_password_change?` hangs off.
  # Both are re-run explicitly below.
  defp seat(email, role, facilitator?, reset?) do
    case Accounts.get_user_by_email(email, not_found_error?: false, authorize?: false) do
      {:ok, nil} ->
        password = generate_password()

        Ash.Seed.seed!(User, %{
          email: email,
          name: name_for(email),
          hashed_password: Bcrypt.hash_pwd_salt(password),
          confirmed_at: DateTime.utc_now(),
          role: role
        })

        new_seat(email, role, password, facilitator?, created?: true)

      {:ok, user} ->
        was = user.role
        user = ensure_role(user, role)

        password =
          if reset? do
            reset_password(user)
          end

        new_seat(email, user.role, password, facilitator?,
          created?: false,
          adopted_from: if(was == role, do: nil, else: was)
        )
    end
  end

  defp new_seat(email, role, password, facilitator?, opts) do
    %{
      email: email,
      role: role,
      password: password,
      facilitator?: facilitator?,
      created?: Keyword.get(opts, :created?, false),
      adopted_from: Keyword.get(opts, :adopted_from)
    }
  end

  # A seat sitting at the wrong tier silently produces spurious S1 findings, so
  # the role is corrected — but through the real action, so the demotion case
  # drops the live sockets that authorized under the old role.
  defp ensure_role(%{role: role} = user, role), do: user

  defp ensure_role(user, role),
    do: Accounts.manage_user_access!(user, %{role: role}, authorize?: false)

  # A seat that exists otherwise keeps its password — the point of the default
  # is that re-running to add a fifth tester does not lock out the four already
  # in a session.
  #
  # When it *is* reset, the reason is almost always that the old credential
  # leaked, so the old one has to actually stop working: `Ash.Seed.update!`
  # writes the hash without going through an action, which means the
  # resource-global `log_out_everywhere` change never fires and the JWT (or a
  # 30-day remember-me cookie) minted under the old password keeps authorizing.
  # Revoking the tokens and evicting the sockets is that add-on's work, done by
  # hand because there is no admin-facing set-password action to route through.
  defp reset_password(user) do
    password = generate_password()

    user = Ash.Seed.update!(user, %{hashed_password: Bcrypt.hash_pwd_salt(password)})

    User
    |> Ash.ActionInput.for_action(:log_out_everywhere, %{user: user})
    |> Ash.run_action!(authorize?: false)

    SessionEviction.evict(user.id, :password_reset)

    password
  end

  defp publisher(seats) do
    seats
    |> Enum.find(&(&1.role == :admin))
    |> case do
      nil -> nil
      %{email: email} -> Accounts.get_user_by_email!(email, authorize?: false)
    end
  end

  defp actor_for(%{email: email}), do: Accounts.get_user_by_email!(email, authorize?: false)

  # 16 bytes of `:crypto.strong_rand_bytes/1`, url64-encoded. Comfortably past
  # the 8-character floor on the password attribute, and never a value anyone
  # is tempted to reuse.
  defp generate_password, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64()

  defp name_for(email) do
    email
    |> String.split("@")
    |> hd()
    |> String.replace(["-", "_", "."], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp tester_emails!(opts, round, domain) do
    case Keyword.get(opts, :emails) do
      nil ->
        count = Keyword.get(opts, :testers, @default_testers)

        unless is_integer(count) and count in 1..@max_testers do
          raise ArgumentError,
                "--testers must be between 1 and #{@max_testers}, got: #{inspect(count)}"
        end

        Enum.map(1..count, &"beta-r#{round}-t#{&1}@#{domain}")

      emails when is_list(emails) ->
        # Trim *before* the emptiness check, or `--tester "  "` reduces to an
        # empty list further down and provisions a round with no testers at all,
        # reporting success.
        emails = emails |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        if emails == [], do: raise(ArgumentError, "no tester emails given")

        # Two seats resolving to one account is not a five-tester round, and it
        # fails in the least obvious place: the second seat overwrites the
        # first's role and (with --reset-passwords) its password, so a tester
        # mid-session is logged out by the provisioning of a colleague.
        case emails -- Enum.uniq(emails) do
          [] -> emails
          dupes -> raise ArgumentError, "duplicate tester emails: #{Enum.join(dupes, ", ")}"
        end

      other ->
        raise ArgumentError, "tester emails must be a list, got: #{inspect(other)}"
    end
  end

  defp shape!(shape) when shape in [:authoring, :operator], do: shape
  defp shape!("authoring"), do: :authoring
  defp shape!("operator"), do: :operator
  defp shape!(other), do: raise(ArgumentError, "unknown round shape #{inspect(other)}")

  # --- seed content ---------------------------------------------------------

  # "Seed each tester with content they can safely break — an empty CMS tests
  # nothing but the empty states." Two records each, both chosen because a
  # scenario in docs/beta-testing.md needs them to exist:
  #
  #   * a published post — Scenario A's edit/unpublish/archive steps have a
  #     live record to act on without the tester having to publish first
  #     (which, as an editor, they cannot);
  #   * a draft page with a prior version — `restore_version` is one of the
  #     few workflow actions an editor *is* allowed, and with a single-version
  #     record it has nothing to restore to.
  #
  # Content is created **as the tester**, so `relate_actor(:author)` stamps them
  # and the create runs through the same policies their session will.
  defp seed_for(tester, round, publisher) do
    actor = actor_for(tester)
    tenant = Accounts.default_org_id()
    handle = handle_for(tester.email)
    display = name_for(tester.email)

    published = seed_post(handle, display, round, actor, publisher, tenant)
    draft = seed_page(handle, display, round, actor, tenant)

    published + draft
  end

  # The **whole** address, not the local part. Two testers from different
  # companies who are both called alice collide on a local-part handle, and the
  # collision is silent: the second one's `exists?/3` finds the first one's
  # record, seeds nothing, and shows up to the session with an empty CMS —
  # which is the exact failure seeding exists to prevent.
  defp handle_for(email) do
    email
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp seed_post(handle, display, round, actor, publisher, tenant) do
    slug = "beta-r#{round}-#{handle}-post"

    if exists?(&CMS.list_posts!/1, &CMS.list_trashed_posts!/1, slug, tenant) do
      0
    else
      post =
        CMS.create_post!(
          %{
            title: "#{display}'s sandbox post",
            slug: slug,
            excerpt: "Yours for this round — edit it, break it, tell us what happened.",
            blocks: [
              %{
                type: :heading,
                content: "#{display}'s sandbox post",
                data: %{"level" => 1},
                order: 0
              },
              %{
                type: :rich_text,
                content:
                  "<p>This post is seeded for beta round #{round}. Nothing here is precious — change anything.</p>",
                order: 1
              }
            ]
          },
          actor: actor,
          tenant: tenant
        )

      # Publishing is the admin approval step, so it runs as the publisher and
      # not the tester. Without an admin seat there is nothing published to act
      # on — which is itself the round-shape finding, so it degrades to a draft
      # rather than raising.
      if publisher do
        CMS.publish_post!(post, %{}, actor: publisher, tenant: tenant)
      end

      1
    end
  end

  defp seed_page(handle, display, round, actor, tenant) do
    slug = "beta-r#{round}-#{handle}-page"

    if exists?(&CMS.list_pages!/1, &CMS.list_trashed_pages!/1, slug, tenant) do
      0
    else
      page =
        CMS.create_page!(
          %{
            title: "#{display}'s scratch page",
            slug: slug,
            blocks: [%{type: :rich_text, content: "<p>First draft.</p>", order: 0}]
          },
          actor: actor,
          tenant: tenant
        )

      # The second write is the point: it gives version history a row, so the
      # tester has something to diff and restore to.
      CMS.update_page!(
        page,
        %{
          blocks: [
            %{
              type: :rich_text,
              content: "<p>Second draft — the first is in history.</p>",
              order: 0
            }
          ]
        },
        actor: actor,
        tenant: tenant
      )

      1
    end
  end

  # The trashed read matters: AshArchival filters `archived_at` out of the
  # primary read, but the `unique_slug` identity is not partial — a soft-deleted
  # record still owns its slug. The beta script *tells* testers to delete a
  # draft and recover it from trash, so a re-run that only consulted the live
  # read would find nothing, try to create, and die on the unique constraint
  # halfway through the round.
  defp exists?(lister, trashed_lister, slug, tenant) do
    query = [query: [filter: [slug: slug]], authorize?: false, tenant: tenant]

    lister.(query) != [] or trashed_lister.(query) != []
  end

  # --- readiness ------------------------------------------------------------

  # Not fatal — a round can run without visual editing or object storage. The
  # point is that the facilitator finds out now rather than when a tester is
  # three minutes into Scenario B.
  defp readiness(shape) do
    [
      commit_readiness(KilnCMS.Beta.frozen_commit()),
      storage_readiness(),
      presentation_readiness(shape)
    ]
  end

  @doc false
  # Public-but-hidden so the three branches can be tested deterministically —
  # the dirty/clean one is the load-bearing half and depends on the working tree
  # the suite happens to run in.
  @spec commit_readiness({String.t(), boolean()} | :unknown) ::
          {String.t(), :ok | :warn, String.t()}
  def commit_readiness(:unknown),
    do: {"frozen commit", :warn, "not a git checkout — record the build another way"}

  def commit_readiness({sha, true}),
    do: {"frozen commit", :warn, "#{sha} (working tree DIRTY — testers can't be given this)"}

  def commit_readiness({sha, false}), do: {"frozen commit", :ok, sha}

  defp storage_readiness do
    case KilnCMS.Storage.adapter() do
      KilnCMS.Storage.Local ->
        {"media storage", :warn, "local disk — uploads are lost when the container restarts"}

      adapter ->
        {"media storage", :ok, inspect(adapter)}
    end
  end

  defp presentation_readiness(shape) do
    cond do
      KilnCMSWeb.Presentation.configured?() ->
        {"presentation preview", :ok, "PRESENTATION_PREVIEW_URL set"}

      shape == :operator ->
        {"presentation preview", :ok, "unset — Scenario G doesn't need it"}

      true ->
        {"presentation preview", :warn,
         "PRESENTATION_PREVIEW_URL unset — skip the console step of the script"}
    end
  end
end
