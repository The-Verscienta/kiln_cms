# Seeds the "Acme" example catalog with synthetic demo content. Unlike the
# overlay's old Sanity-derived import, this is fully self-contained — no
# external export file, so it runs out of the box against any activated
# overlay. Run with:
#
#     mix run projects/example/priv/repo/example_import.exs
#
# Idempotent by (slug, locale): existing records are updated, missing ones
# created and published. Safe to re-run after edits to this file.
#
# Requires the example overlay to be active (config/project.exs registers
# Example.Catalog — see projects/example/README.md), and must run after
# `example_field_definitions.exs` (custom-field values are validated against
# the definitions on every write) and `example_dynamic_types.exs` (the Event
# entries below need the "event" type to already exist).
#
# Deliberately skips real media/featured images: kiln_cms's media pipeline
# expects Cloudflare-hosted assets (`csp_img_src` in `project.exs`), which a
# synthetic seed can't produce without a real upload step. Every other block
# type is fair game, and the seeded bodies deliberately mix several different
# ones (heading, rich_text, quote, accordion, how_to, divider, the
# plugin-contributed `stat`, and the core `form` block) so the block editor's
# breadth is visible in seeded content, not just structurally available.

require Ash.Query

alias Example.Catalog
alias KilnCMS.Accounts
alias KilnCMS.CMS

admin_email = System.get_env("ADMIN_EMAIL", "admin@kiln.test")

admin =
  case Accounts.get_user_by_email(admin_email, not_found_error?: false, authorize?: false) do
    {:ok, %{role: :admin} = user} -> user
    _ -> raise "No admin user for #{admin_email} — run priv/repo/seeds.exs first."
  end

tenant = Accounts.default_org_id()
opts = [actor: admin, tenant: tenant]

# --- Request-a-demo form (embedded via the `form` block on one Product) ----

form =
  case CMS.get_active_form_by_slug("request-a-demo", opts ++ [not_found_error?: false]) do
    {:ok, %{} = form} ->
      form

    _not_found ->
      form =
        CMS.create_form!(
          %{name: "Request a demo", slug: "request-a-demo", submit_label: "Request demo"},
          opts
        )

      existing_fields = CMS.form_fields_for!(form.id, opts) |> MapSet.new(& &1.name)

      [
        %{name: "name", label: "Name", field_type: :string, required: true, position: 0},
        %{name: "email", label: "Work email", field_type: :email, required: true, position: 1},
        %{name: "company", label: "Company", field_type: :string, position: 2}
      ]
      |> Enum.reject(&MapSet.member?(existing_fields, &1.name))
      |> Enum.each(&CMS.create_form_field!(Map.put(&1, :form_id, form.id), opts))

      form
  end

IO.puts("form: #{form.slug} ready")

# --- Shared helpers ----------------------------------------------------------

# Per-type code interfaces (bang variants; create/list arity 2, update/publish
# arity 3: record, params, opts). `domain` is `KilnCMS.CMS` for the core
# `post` type mentioned in field definitions but not seeded here, `Example.Catalog`
# for the overlay's own four types.
interfaces =
  Map.new(~w(product team_member testimonial faq), fn type ->
    plural = if type == "faq", do: "faqs", else: "#{type}s"

    {type,
     %{
       list: Function.capture(Catalog, :"list_#{plural}!", 2),
       create: Function.capture(Catalog, :"create_#{type}!", 2),
       update: Function.capture(Catalog, :"update_#{type}!", 3),
       publish: Function.capture(Catalog, :"publish_#{type}!", 3)
     }}
  end)

# Upserts by (slug, locale) and publishes drafts. Returns the row.
upsert_publish = fn type, attrs ->
  %{list: list, create: create, update: update, publish: publish} = interfaces[type]
  locale = Map.get(attrs, :locale, "en")

  existing =
    list.(%{}, opts)
    |> Enum.find(&(&1.slug == attrs.slug and &1.locale == locale))

  row =
    case existing do
      nil -> create.(attrs, opts)
      row -> update.(row, Map.delete(attrs, :slug), opts)
    end

  if row.state in [:draft, :in_review], do: publish.(row, %{}, opts), else: row
end

# --- Products ----------------------------------------------------------------

money = fn amount, currency -> %{"amount" => amount, "currency" => currency} end

products =
  [
    %{
      title: "Widget Pro",
      slug: "widget-pro",
      excerpt: "Our flagship widget, built for teams that ship fast.",
      custom_fields: %{
        "category" => "hardware",
        "sku" => "WP-100",
        "price" => money.(99.0, "USD"),
        "features" => "Aluminum housing\nWireless sync\n2-year warranty",
        "featured" => true,
        "display_order" => 0
      },
      blocks: [
        %{"_type" => "heading", "text" => "Everything you need, out of the box", "level" => 2},
        %{
          "_type" => "rich_text",
          "legacy_html" => "<p>Widget Pro pairs with every Acme product below.</p>"
        },
        %{"_type" => "stat", "value" => "10,000+", "label" => "customers served"},
        %{
          "_type" => "accordion",
          "title" => "Specs",
          "panels" => [
            %{"title" => "Dimensions", "content" => "12 × 8 × 3 cm"},
            %{"title" => "Battery", "content" => "18-hour typical use"}
          ]
        }
      ]
    },
    %{
      title: "Cloud Sync",
      slug: "cloud-sync",
      excerpt: "Real-time sync for every Acme device.",
      custom_fields: %{
        "category" => "software",
        "sku" => "CS-200",
        "price" => money.(29.0, "USD"),
        "features" => "End-to-end encryption\nOffline queue\nAudit log",
        "featured" => true,
        "display_order" => 1
      },
      blocks: [
        %{
          "_type" => "how_to",
          "name" => "Connect a device",
          "steps" => [
            %{"name" => "Install", "text" => "Download Cloud Sync from your device's app store."},
            %{"name" => "Sign in", "text" => "Use your Acme account to sign in."},
            %{"name" => "Sync", "text" => "Devices sync automatically once signed in."}
          ]
        },
        %{"_type" => "divider"},
        %{"_type" => "form", "form_slug" => "request-a-demo"}
      ]
    },
    %{
      title: "Onboarding Package",
      slug: "onboarding-package",
      excerpt: "White-glove setup for larger teams.",
      # Audience-gated (#337): only signed-in `:member` readers see this record.
      audience: :member,
      custom_fields: %{
        "category" => "services",
        "sku" => "OB-300",
        "price" => money.(499.0, "USD"),
        "display_order" => 2
      },
      blocks: [
        %{"_type" => "rich_text", "legacy_html" => "<p>Available to registered customers.</p>"}
      ]
    },
    %{
      title: "Internal Beta Kit",
      slug: "internal-beta-kit",
      excerpt: "Early-access hardware for design partners.",
      # Passphrase-locked (#496): the passphrase is "acme-preview-2026".
      # `access_password` is a write-only argument — `Changes.ApplyAccessPassword`
      # hashes it into `access_password_hash`/`password_fingerprint`.
      access_password: "acme-preview-2026",
      custom_fields: %{
        "category" => "accessories",
        "sku" => "BK-400",
        "price" => money.(0.0, "USD"),
        "display_order" => 3
      },
      blocks: [
        %{
          "_type" => "quote",
          "text" => "Design-partner exclusive — do not share outside your org.",
          "citation" => "Acme Beta Program"
        }
      ]
    },
    %{
      title: "Widget Case",
      slug: "widget-case",
      excerpt: "A protective case for Widget Pro.",
      custom_fields: %{
        "category" => "accessories",
        "sku" => "WC-500",
        "price" => money.(15.0, "USD"),
        "display_order" => 4
      },
      blocks: [%{"_type" => "rich_text", "legacy_html" => "<p>Fits Widget Pro snugly.</p>"}]
    }
  ]
  |> Enum.map(&upsert_publish.("product", &1))
  |> Map.new(&{&1.slug, &1})

IO.puts("products: #{map_size(products)} ready")

# --- Team members --------------------------------------------------------------

team_members =
  [
    %{
      title: "Ada Rivera",
      slug: "ada-rivera",
      excerpt: "Senior Product Engineer",
      custom_fields: %{
        "role" => "Senior Product Engineer",
        "department" => "engineering",
        "social_links" =>
          "GitHub | https://github.com/example\nLinkedIn | https://linkedin.com/in/example",
        "years_experience" => 8,
        "email" => "ada@acme.example"
      },
      blocks: [
        %{
          "_type" => "rich_text",
          "legacy_html" => "<p>Ada leads the Widget Pro platform team.</p>"
        }
      ]
    },
    %{
      title: "Marcus Chen",
      slug: "marcus-chen",
      excerpt: "Head of Customer Support",
      custom_fields: %{
        "role" => "Head of Customer Support",
        "department" => "support",
        "years_experience" => 6,
        "email" => "marcus@acme.example"
      },
      blocks: []
    },
    %{
      title: "Priya Nathan",
      slug: "priya-nathan",
      excerpt: "VP Sales",
      custom_fields: %{
        "role" => "VP Sales",
        "department" => "sales",
        "years_experience" => 11,
        "email" => "priya@acme.example"
      },
      blocks: []
    }
  ]
  |> Enum.map(&upsert_publish.("team_member", &1))
  |> Map.new(&{&1.slug, &1})

IO.puts("team_members: #{map_size(team_members)} ready")

# --- Testimonials (linked to a Product via ContentLink) ---------------------

testimonials_attrs = [
  %{
    title: "Globex Corp",
    slug: "globex-corp",
    excerpt: "\"Widget Pro paid for itself in a month.\"",
    custom_fields: %{
      "customer_title" => "Operations Lead, Globex Corp",
      "rating" => 5,
      "review_date" => "2026-06-02",
      "featured" => true,
      "verified" => true
    },
    blocks: [
      %{
        "_type" => "quote",
        "text" => "Widget Pro paid for itself in a month.",
        "citation" => "Operations Lead, Globex Corp"
      }
    ],
    related_product_slug: "widget-pro"
  },
  %{
    title: "Initech",
    slug: "initech",
    excerpt: "\"Cloud Sync just works, across every device.\"",
    custom_fields: %{
      "customer_title" => "CTO, Initech",
      "rating" => 4,
      "review_date" => "2026-05-14",
      "verified" => true
    },
    blocks: [
      %{
        "_type" => "quote",
        "text" => "Cloud Sync just works, across every device.",
        "citation" => "CTO, Initech"
      }
    ],
    related_product_slug: "cloud-sync"
  }
]

testimonials =
  testimonials_attrs
  |> Enum.map(&upsert_publish.("testimonial", Map.delete(&1, :related_product_slug)))
  |> Map.new(&{&1.slug, &1})

links_created =
  testimonials_attrs
  |> Enum.reduce(0, fn %{slug: slug, related_product_slug: product_slug}, n ->
    with %{} = testimonial <- testimonials[slug],
         %{} = product <- products[product_slug],
         # `Ash.exists?/2` on a filtered query, not a `list_content_links!`
         # scan or a `content_links` relationship load: `kind` is an
         # open-ended atom column (`Ash.Type.Atom.EctoType`), and Ecto
         # decodes every matched row's `kind` into a struct field —
         # including one this run never referenced as a literal atom, which
         # raises rather than returning an unmatched value. `exists?`
         # filters `kind == :related` server-side, so Postgres excludes
         # any other-kind row before a row is ever materialized.
         false <-
           KilnCMS.CMS.ContentLink
           |> Ash.Query.filter(
             source_id == ^testimonial.id and target_id == ^product.id and kind == :related
           )
           |> Ash.exists?(opts) do
      CMS.create_content_link!(
        %{source_id: testimonial.id, target_id: product.id, kind: :related},
        opts
      )

      n + 1
    else
      _ -> n
    end
  end)

IO.puts(
  "testimonials: #{map_size(testimonials)} ready, #{links_created} new related-product links"
)

# --- FAQs (one seeded in two locales) ---------------------------------------

faqs_attrs = [
  %{
    title: "How do I get started?",
    slug: "getting-started",
    locale: "en",
    custom_fields: %{"category" => "getting-started", "featured" => true, "display_order" => 0},
    blocks: [
      %{
        "_type" => "rich_text",
        "legacy_html" => "<p>Create an account, then follow the setup wizard.</p>"
      }
    ]
  },
  %{
    title: "¿Cómo empiezo?",
    slug: "getting-started",
    locale: "es",
    custom_fields: %{"category" => "getting-started", "featured" => true, "display_order" => 0},
    blocks: [
      %{
        "_type" => "rich_text",
        "legacy_html" => "<p>Crea una cuenta y sigue el asistente de configuración.</p>"
      }
    ]
  },
  %{
    title: "What payment methods do you accept?",
    slug: "payment-methods",
    custom_fields: %{"category" => "billing", "display_order" => 0},
    blocks: [
      %{
        "_type" => "rich_text",
        "legacy_html" => "<p>All major credit cards and ACH transfer.</p>"
      }
    ]
  },
  %{
    title: "How do I reset my password?",
    slug: "reset-password",
    custom_fields: %{"category" => "account", "display_order" => 0},
    blocks: [
      %{
        "_type" => "rich_text",
        "legacy_html" => "<p>Use the \"Forgot password\" link on the sign-in page.</p>"
      }
    ]
  },
  %{
    title: "Do you offer integrations?",
    slug: "integrations",
    custom_fields: %{"category" => "integrations", "display_order" => 0},
    blocks: [
      %{"_type" => "rich_text", "legacy_html" => "<p>Yes — see our integrations directory.</p>"}
    ]
  }
]

faqs =
  faqs_attrs
  |> Enum.map(&upsert_publish.("faq", &1))

IO.puts("faqs: #{length(faqs)} ready (including 1 entry in 2 locales)")

# --- Events (admin-defined dynamic type, D17) -------------------------------

event_type =
  case CMS.get_type_definition_by_name("event", opts) do
    {:ok, type} -> type
    _ -> raise "No \"event\" type — run example_dynamic_types.exs first."
  end

existing_entries =
  CMS.list_entries!(%{}, opts) |> Enum.filter(&(&1.type_definition_id == event_type.id))

upsert_publish_entry = fn attrs ->
  attrs = Map.put(attrs, :type_definition_id, event_type.id)

  row =
    case Enum.find(existing_entries, &(&1.slug == attrs.slug)) do
      nil -> CMS.create_entry!(attrs, opts)
      row -> CMS.update_entry!(row, Map.drop(attrs, [:slug, :type_definition_id]), opts)
    end

  if row.state in [:draft, :in_review], do: CMS.publish_entry!(row, %{}, opts), else: row
end

events =
  [
    %{
      title: "Product Launch Webinar",
      slug: "product-launch-webinar",
      excerpt: "See Widget Pro's newest features live.",
      custom_fields: %{
        "schedule" => %{
          "start" => "2026-09-15T18:00:00",
          "end" => "2026-09-15T19:00:00",
          "time_zone" => "America/New_York"
        },
        "location" => "Online"
      },
      blocks: [
        %{"_type" => "rich_text", "legacy_html" => "<p>Join us for a live walkthrough.</p>"}
      ]
    },
    %{
      title: "Acme User Conference",
      slug: "acme-user-conference",
      excerpt: "Two days of workshops and customer talks.",
      custom_fields: %{
        "schedule" => %{
          "start" => "2026-10-06T09:00:00",
          "end" => "2026-10-07T17:00:00",
          "time_zone" => "America/Chicago"
        },
        "location" => "Austin, TX"
      },
      blocks: [%{"_type" => "heading", "text" => "Two days, one Acme", "level" => 2}]
    },
    %{
      title: "Weekly Office Hours",
      slug: "weekly-office-hours",
      excerpt: "Drop-in Q&A with the Acme product team.",
      custom_fields: %{
        "schedule" => %{
          "start" => "2026-08-18T16:00:00",
          "end" => "2026-08-18T16:30:00",
          "time_zone" => "America/New_York"
        },
        "recurrence" => %{"rrule" => "FREQ=WEEKLY;BYDAY=TU"},
        "location" => "Online"
      },
      blocks: []
    }
  ]
  |> Enum.map(upsert_publish_entry)

IO.puts("events: #{length(events)} ready")

IO.puts("Import finished.")
