# Custom-field definitions for the acupuncture content types
# (Condition, TeamMember, Testimonial, Faq). Run with:
#
#     mix run priv/repo/acupuncture_field_definitions.exs
#
# Idempotent: each definition is looked up by its (content_type, name)
# identity and created or updated to match this file, so the script is the
# source of truth and safe to re-run after edits.
#
# Fields the core Content resource already covers are deliberately absent:
# title (name/question/author), excerpt (short bio / description / quote),
# blocks (bio / detailed description / answer), featured_image (photo/avatar),
# seo_*, and related_conditions (ContentLink). Sanity's list-of-string and
# list-of-object fields map to :text with a one-entry-per-line convention
# (" | "-separated parts for structured entries) — the registry has no
# repeating-group type.

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

condition_categories = ~w(pain mental-health womens-health digestive immune other)

faq_categories =
  ~w(about-acupuncture treatment-process insurance-payment appointments-policies safety-side-effects our-practice)

definitions = [
  # --- condition -----------------------------------------------------------
  %{
    content_type: :condition,
    name: "category",
    label: "Category",
    field_type: :select,
    options: condition_categories,
    required: true,
    help_text: "Grouping used by the conditions index page filters."
  },
  %{
    content_type: :condition,
    name: "icon",
    label: "Icon",
    field_type: :text,
    help_text: "Emoji or inline SVG shown on the conditions grid card."
  },
  %{
    content_type: :condition,
    name: "symptoms",
    label: "Common symptoms",
    field_type: :text,
    help_text: "One symptom per line."
  },
  %{
    content_type: :condition,
    name: "treatment_duration",
    label: "Typical treatment duration",
    field_type: :string,
    help_text: "e.g. \"6–12 sessions over 2–3 months\""
  },
  %{
    content_type: :condition,
    name: "featured",
    label: "Featured on homepage",
    field_type: :boolean,
    default: "false"
  },
  %{
    content_type: :condition,
    name: "display_order",
    label: "Display order",
    field_type: :integer,
    default: "0",
    help_text: "Lower numbers sort first on the conditions index."
  },

  # --- team_member ---------------------------------------------------------
  %{
    content_type: :team_member,
    name: "role",
    label: "Role",
    field_type: :string,
    required: true,
    help_text: "e.g. \"Licensed Acupuncturist\""
  },
  %{
    content_type: :team_member,
    name: "credentials",
    label: "Credentials",
    field_type: :string,
    help_text: "Post-nominal letters, e.g. \"L.Ac., MSOM\"."
  },
  %{
    content_type: :team_member,
    name: "specialties",
    label: "Specialties",
    field_type: :text,
    help_text: "One specialty per line."
  },
  %{
    content_type: :team_member,
    name: "certifications",
    label: "Certifications",
    field_type: :text,
    help_text: "One per line: Title | Issuing organization | Year."
  },
  %{
    content_type: :team_member,
    name: "education",
    label: "Education",
    field_type: :text,
    help_text: "One per line: Degree | School | Year."
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

  # --- testimonial ---------------------------------------------------------
  %{
    content_type: :testimonial,
    name: "condition_treated",
    label: "Condition treated",
    field_type: :string,
    help_text: "Free-text condition shown under the author name."
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
    label: "Verified patient",
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

IO.puts("Seeding acupuncture custom-field definitions…")

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

IO.puts("Done: #{length(definitions)} definitions across 4 content types.")
