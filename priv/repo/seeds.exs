# Script for populating the database. Run with:
#
#     mix run priv/repo/seeds.exs
#
# Also invoked automatically by the `setup` and `ecto.setup` mix aliases.
#
# The script is **idempotent** — it looks up records by their natural key
# (email / slug) and only creates what is missing, so it is safe to re-run.
#
# Credentials default to dev-only values and can be overridden with the
# ADMIN_EMAIL / ADMIN_PASSWORD / EDITOR_EMAIL / EDITOR_PASSWORD env vars.
#
# Per the Ash usage rules, all data access goes through the domain code
# interfaces (`Accounts.*` / `CMS.*`) rather than raw `Ash.create!/read!`.

alias KilnCMS.Accounts
alias KilnCMS.Accounts.User

alias KilnCMS.CMS

# --- Users -----------------------------------------------------------------

# Roles can't be set through `register_with_password` (it always defaults to
# :viewer so self-registration can't escalate), and we want the demo accounts
# pre-confirmed, so seed them directly via Ash.Seed.
#
# A display name as well, for the DEMO accounts only: `@mentions` in editorial
# comments resolve against the member's normalised NAME
# (`KilnCMS.CMS.Mentions`), so a nameless user cannot be mentioned at all —
# which made the mention journey undrivable against a seeded database
# (#1314). An existing nameless demo user (a database seeded before this was
# added) is backfilled rather than left as is, so re-running the seeds
# converges on the same state a fresh one gets. `name` is nil whenever the
# email was overridden: ADMIN_EMAIL is also how an operator bootstraps a REAL
# admin (README), and that account's name is theirs to set — it is the byline
# on everything they publish, and this script must stay safe to re-run.
seed_user = fn email, password, role, name ->
  case Accounts.get_user_by_email(email, not_found_error?: false, authorize?: false) do
    {:ok, nil} ->
      user =
        Ash.Seed.seed!(User, %{
          email: email,
          name: name,
          hashed_password: Bcrypt.hash_pwd_salt(password),
          confirmed_at: DateTime.utc_now(),
          role: role
        })

      IO.puts("  created #{role} user: #{email}")
      user

    {:ok, %{name: current} = user} when current in [nil, ""] and is_binary(name) ->
      IO.puts("  #{role} user already exists: #{email} (adding display name)")
      Ash.Seed.update!(user, %{name: name})

    {:ok, user} ->
      IO.puts("  #{role} user already exists: #{email}")
      user
  end
end

admin_email = System.get_env("ADMIN_EMAIL", "admin@kiln.test")
admin_password = System.get_env("ADMIN_PASSWORD", "kilnadmin123")
editor_email = System.get_env("EDITOR_EMAIL", "editor@kiln.test")
editor_password = System.get_env("EDITOR_PASSWORD", "kilneditor123")

# Only the stock demo addresses get a demo name — see `seed_user` above.
demo_name = fn email, default_email, name -> if email == default_email, do: name end

IO.puts("Seeding users…")

admin =
  seed_user.(
    admin_email,
    admin_password,
    :admin,
    demo_name.(admin_email, "admin@kiln.test", "Demo Admin")
  )

_editor =
  seed_user.(
    editor_email,
    editor_password,
    :editor,
    demo_name.(editor_email, "editor@kiln.test", "Demo Editor")
  )

# --- Demo content ----------------------------------------------------------

# Content goes through the real domain actions as the admin actor so it
# exercises the same policies, validations, paper-trail versioning, and publish
# workflow the app uses at runtime. `list`/`create`/`publish` are the resource's
# code interfaces, captured per content item so each call uses the correct one.
ensure_content = fn label, list, create, publish ->
  case list.() do
    [] ->
      record = create.()
      record = if publish, do: publish.(record), else: record
      IO.puts("  created #{label}: #{record.slug} (#{record.state})")

    [_existing | _] ->
      IO.puts("  #{label} already exists")
  end
end

IO.puts("Seeding demo content…")

ensure_content.(
  "page welcome",
  fn ->
    CMS.list_pages!(
      query: [filter: [slug: "welcome"]],
      authorize?: false,
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end,
  fn ->
    CMS.create_page!(
      %{
        title: "Welcome to KilnCMS",
        slug: "welcome",
        seo_title: "Welcome to KilnCMS",
        seo_description: "A world-class, Elixir-native headless CMS.",
        blocks: [
          %{type: :heading, content: "Welcome to KilnCMS", data: %{"level" => 1}, order: 0},
          %{
            type: :rich_text,
            content:
              "<p>This page was created by the seed script and published via the workflow.</p>",
            order: 1
          }
        ]
      },
      actor: admin,
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end,
  fn page ->
    CMS.publish_page!(page, %{}, actor: admin, tenant: KilnCMS.Accounts.default_org_id())
  end
)

ensure_content.(
  "page about",
  fn ->
    CMS.list_pages!(
      query: [filter: [slug: "about"]],
      authorize?: false,
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end,
  fn ->
    CMS.create_page!(
      %{
        title: "About",
        slug: "about",
        blocks: [
          %{type: :rich_text, content: "<p>This is an unpublished draft page.</p>", order: 0}
        ]
      },
      actor: admin,
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end,
  nil
)

ensure_content.(
  "post hello-world",
  fn ->
    CMS.list_posts!(
      query: [filter: [slug: "hello-world"]],
      authorize?: false,
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end,
  fn ->
    CMS.create_post!(
      %{
        title: "Hello, World",
        slug: "hello-world",
        excerpt: "The first post on a KilnCMS-powered site.",
        blocks: [
          %{type: :heading, content: "Hello, World", data: %{"level" => 1}, order: 0},
          %{
            type: :rich_text,
            content:
              "<p>KilnCMS pairs Ash's declarative modeling with LiveView's real-time UX.</p>",
            order: 1
          }
        ]
      },
      actor: admin,
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end,
  fn post ->
    CMS.publish_post!(post, %{}, actor: admin, tenant: KilnCMS.Accounts.default_org_id())
  end
)

IO.puts("Seeding complete.")
