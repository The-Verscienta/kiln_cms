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

require Ash.Query
import Ash.Expr

alias KilnCMS.Accounts.User
alias KilnCMS.CMS.{Page, Post}

# --- Users -----------------------------------------------------------------

# Roles can't be set through `register_with_password` (it always defaults to
# :viewer so self-registration can't escalate), and we want the demo accounts
# pre-confirmed, so seed them directly via Ash.Seed.
seed_user = fn email, password, role ->
  case User |> Ash.Query.filter(email == ^email) |> Ash.read_one!(authorize?: false) do
    nil ->
      user =
        Ash.Seed.seed!(User, %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(password),
          confirmed_at: DateTime.utc_now(),
          role: role
        })

      IO.puts("  created #{role} user: #{email}")
      user

    user ->
      IO.puts("  #{role} user already exists: #{email}")
      user
  end
end

admin_email = System.get_env("ADMIN_EMAIL", "admin@kiln.test")
admin_password = System.get_env("ADMIN_PASSWORD", "kilnadmin123")
editor_email = System.get_env("EDITOR_EMAIL", "editor@kiln.test")
editor_password = System.get_env("EDITOR_PASSWORD", "kilneditor123")

IO.puts("Seeding users…")
admin = seed_user.(admin_email, admin_password, :admin)
_editor = seed_user.(editor_email, editor_password, :editor)

# --- Demo content ----------------------------------------------------------

# Content goes through the real Ash actions as the admin actor so it exercises
# the same policies, validations, paper-trail versioning, and publish workflow
# the app uses at runtime.
ensure_content = fn resource, slug, create_attrs, publish? ->
  case resource |> Ash.Query.filter(slug == ^slug) |> Ash.read_one!(authorize?: false) do
    nil ->
      record = Ash.create!(resource, create_attrs, actor: admin)

      record =
        if publish? do
          Ash.update!(record, %{}, action: :publish, actor: admin)
        else
          record
        end

      IO.puts("  created #{inspect(resource)}: #{slug} (#{record.state})")

    _existing ->
      IO.puts("  #{inspect(resource)} already exists: #{slug}")
  end
end

IO.puts("Seeding demo content…")

ensure_content.(
  Page,
  "welcome",
  %{
    title: "Welcome to KilnCMS",
    slug: "welcome",
    seo_title: "Welcome to KilnCMS",
    seo_description: "A world-class, Elixir-native headless CMS.",
    blocks: [
      %{type: :heading, content: "Welcome to KilnCMS", data: %{"level" => 1}, order: 0},
      %{
        type: :rich_text,
        content: "<p>This page was created by the seed script and published via the workflow.</p>",
        order: 1
      }
    ]
  },
  true
)

ensure_content.(
  Page,
  "about",
  %{
    title: "About",
    slug: "about",
    blocks: [
      %{type: :rich_text, content: "<p>This is an unpublished draft page.</p>", order: 0}
    ]
  },
  false
)

ensure_content.(
  Post,
  "hello-world",
  %{
    title: "Hello, World",
    slug: "hello-world",
    excerpt: "The first post on a KilnCMS-powered site.",
    blocks: [
      %{type: :heading, content: "Hello, World", data: %{"level" => 1}, order: 0},
      %{
        type: :rich_text,
        content: "<p>KilnCMS pairs Ash's declarative modeling with LiveView's real-time UX.</p>",
        order: 1
      }
    ]
  },
  true
)

IO.puts("Seeding complete.")
