# Custom-field definitions for the "Acme" example catalog (Product,
# TeamMember, Testimonial, Faq) plus two on the core `post` type. Run with:
#
#     mix run projects/example/priv/repo/example_field_definitions.exs
#
# Idempotent: each definition is looked up by its (content_type, name)
# identity and created or updated to match this file, so the script is the
# source of truth and safe to re-run after edits.
#
# Fields the core Content resource already covers are deliberately absent:
# title (name/question/author), excerpt (short description/quote), blocks
# (body/bio/answer), featured_image (photo), seo_*, and the standard
# related-content relationship (used for Testimonial → Product links). List
# data maps to :text with a one-entry-per-line convention (" | "-separated
# parts for structured entries) — the registry has no repeating-group type.
#
# `price`'s `field_type: :money` is a plugin-contributed custom field type
# (`Example.FieldTypes.Money`, registered via `Example.Plugin.field_types/0`)
# — every other field here uses a core type.

alias KilnCMS.Accounts
alias KilnCMS.CMS

admin_email = System.get_env("ADMIN_EMAIL", "admin@kiln.test")

admin =
  case Accounts.get_user_by_email(admin_email, not_found_error?: false, authorize?: false) do
    {:ok, %{role: :admin} = user} ->
      user

    _ ->
      raise "No admin user found for #{admin_email} — run priv/repo/seeds.exs first " <>
              "or set ADMIN_EMAIL."
  end

product_categories = ~w(hardware software services accessories other)
department_options = ~w(engineering sales support leadership other)
faq_categories = ~w(getting-started billing account security integrations general)

definitions = [
  # --- post (core type; a byline for posts authored by a team member) ------
  %{
    content_type: :post,
    name: "featured",
    label: "Featured on homepage",
    field_type: :boolean,
    default: "false"
  },
  %{
    content_type: :post,
    name: "author_name",
    label: "Author name",
    field_type: :string,
    help_text: "Display byline (team members are not necessarily CMS users)."
  },
  %{
    content_type: :post,
    name: "author_slug",
    label: "Author slug",
    field_type: :string,
    help_text: "Team-member slug the byline links to."
  },

  # --- product ---------------------------------------------------------------
  %{
    content_type: :product,
    name: "category",
    label: "Category",
    field_type: :select,
    options: product_categories,
    required: true,
    help_text: "Grouping used by the products index page filters and the alias pattern."
  },
  %{
    content_type: :product,
    name: "sku",
    label: "SKU",
    field_type: :string,
    help_text: "Stock-keeping unit / product code."
  },
  %{
    content_type: :product,
    name: "price",
    label: "Price",
    field_type: :money,
    help_text: "Amount and ISO currency code, e.g. 49.00 USD."
  },
  %{
    content_type: :product,
    name: "features",
    label: "Key features",
    field_type: :text,
    help_text: "One feature per line."
  },
  %{
    content_type: :product,
    name: "featured",
    label: "Featured on homepage",
    field_type: :boolean,
    default: "false"
  },
  %{
    content_type: :product,
    name: "display_order",
    label: "Display order",
    field_type: :integer,
    default: "0",
    help_text: "Lower numbers sort first on the products index."
  },

  # --- team_member -----------------------------------------------------------
  %{
    content_type: :team_member,
    name: "role",
    label: "Role",
    field_type: :string,
    required: true,
    help_text: "e.g. \"Senior Product Engineer\""
  },
  %{
    content_type: :team_member,
    name: "department",
    label: "Department",
    field_type: :select,
    options: department_options
  },
  %{
    content_type: :team_member,
    name: "social_links",
    label: "Social links",
    field_type: :text,
    help_text: "One per line: Platform | URL."
  },
  %{
    content_type: :team_member,
    name: "years_experience",
    label: "Years of experience",
    field_type: :integer
  },
  %{
    content_type: :team_member,
    name: "languages",
    label: "Languages",
    field_type: :text,
    help_text: "One language per line."
  },
  %{content_type: :team_member, name: "email", label: "Email", field_type: :string},
  %{content_type: :team_member, name: "phone", label: "Phone", field_type: :string},
  %{
    content_type: :team_member,
    name: "display_order",
    label: "Display order",
    field_type: :integer,
    default: "0",
    help_text: "Lower numbers sort first on the About page."
  },

  # --- testimonial -------------------------------------------------------------
  %{
    content_type: :testimonial,
    name: "customer_title",
    label: "Customer title/company",
    field_type: :string,
    help_text:
      "Free-text attribution shown under the author name, e.g. \"VP Engineering, Globex\"."
  },
  %{
    content_type: :testimonial,
    name: "rating",
    label: "Rating",
    field_type: :integer,
    help_text: "1–5 stars."
  },
  %{
    content_type: :testimonial,
    name: "review_date",
    label: "Review date",
    field_type: :date
  },
  %{
    content_type: :testimonial,
    name: "featured",
    label: "Featured on homepage",
    field_type: :boolean,
    default: "false"
  },
  %{
    content_type: :testimonial,
    name: "verified",
    label: "Verified customer",
    field_type: :boolean,
    default: "false"
  },

  # --- faq -----------------------------------------------------------------
  %{
    content_type: :faq,
    name: "category",
    label: "Category",
    field_type: :select,
    options: faq_categories,
    required: true,
    help_text: "Grouping used by the FAQ page sections."
  },
  %{
    content_type: :faq,
    name: "featured",
    label: "Featured",
    field_type: :boolean,
    default: "false"
  },
  %{
    content_type: :faq,
    name: "display_order",
    label: "Display order",
    field_type: :integer,
    default: "0",
    help_text: "Lower numbers sort first within a category."
  }
]

IO.puts("Seeding Acme example custom-field definitions…")

tenant = KilnCMS.Accounts.default_org_id()

# Positions restart per content type, in this file's order.
definitions
|> Enum.group_by(& &1.content_type)
|> Enum.each(fn {content_type, defs} ->
  existing =
    content_type
    |> CMS.field_definitions_for!(actor: admin, tenant: tenant)
    |> Map.new(&{&1.name, &1})

  defs
  |> Enum.with_index()
  |> Enum.each(fn {attrs, position} ->
    attrs = Map.put(attrs, :position, position)

    case Map.fetch(existing, attrs.name) do
      {:ok, definition} ->
        CMS.update_field_definition!(definition, Map.delete(attrs, :content_type),
          actor: admin,
          tenant: tenant
        )

        IO.puts("  updated #{content_type}.#{attrs.name}")

      :error ->
        CMS.create_field_definition!(attrs, actor: admin, tenant: tenant)
        IO.puts("  created #{content_type}.#{attrs.name}")
    end
  end)
end)

types = definitions |> Enum.map(& &1.content_type) |> Enum.uniq() |> length()
IO.puts("Done: #{length(definitions)} definitions across #{types} content types.")
