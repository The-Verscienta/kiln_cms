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

# Refuse production unless the operator opts in *and* overrides the published
# demo passwords. `mix ecto.setup` against a production DATABASE_URL must not
# create admin@kiln.test / kilnadmin123. First-admin for a real deploy is
# `/setup` (`KilnCMS.Accounts.Bootstrap`).
if Mix.env() == :prod do
  unless System.get_env("ALLOW_PROD_SEEDS") == "confirm" do
    Mix.raise("""
    Refusing to seed in :prod.

    Use /setup for the first admin on a production database, or set
    ALLOW_PROD_SEEDS=confirm together with non-default ADMIN_PASSWORD and
    EDITOR_PASSWORD if you deliberately want this script against a prod DB.
    """)
  end
end

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

if Mix.env() == :prod do
  defaults = [{"kilnadmin123", admin_password}, {"kilneditor123", editor_password}]

  if Enum.any?(defaults, fn {default, actual} -> actual == default end) do
    Mix.raise("""
    Refusing to seed production with the published demo passwords.

    Set ADMIN_PASSWORD and EDITOR_PASSWORD to non-default values when
    ALLOW_PROD_SEEDS=confirm is set.
    """)
  end
end

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
          %{"_type" => "heading", "text" => "Welcome to KilnCMS", "level" => 1},
          %{
            "_type" => "rich_text",
            "body" =>
              KilnCMS.Blocks.PortableText.from_html(
                "<p>This page was created by the seed script and published via the workflow.</p>"
              )
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
          %{
            "_type" => "rich_text",
            "body" =>
              KilnCMS.Blocks.PortableText.from_html("<p>This is an unpublished draft page.</p>")
          }
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
          %{"_type" => "heading", "text" => "Hello, World", "level" => 1},
          %{
            "_type" => "rich_text",
            "body" =>
              KilnCMS.Blocks.PortableText.from_html(
                "<p>KilnCMS pairs Ash's declarative modeling with LiveView's real-time UX.</p>"
              )
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
