# Seeds one example each of the "Acme" example catalog's platform-level
# features — the ones that aren't resource code, so nothing in
# `projects/example/catalog/` demonstrates them on its own. Run with:
#
#     mix run projects/example/priv/repo/example_demo_config.exs
#
# Must run after `example_import.exs` — the experiment and release below
# target already-seeded Product/Form records by slug.
#
# Idempotent: each item is looked up by name/url first.
#
# What's here, and what a real deployment still owes it:
#
#   * Automation rule — reacts on every write, no extra activation needed.
#   * Webhook endpoint — IANA's `example.com` (RFC 2606): a real, resolvable
#     hostname, so it clears `KilnCMS.Webhooks.SafeUrl`'s anti-SSRF
#     resolution check (unlike `.test`/`.invalid`, which are reserved to
#     never resolve and fail that check outright). Deliveries 404 harmlessly
#     against it, since nothing there is listening for a POST. Point `url` at
#     a real endpoint to see it fire.
#   * Experiment — created `:draft` then started, but experiment DELIVERY is
#     also gated by a separate deployment-wide switch
#     (`config :kiln_cms, KilnCMS.Experiments, enabled: true`), off by
#     default in every env including this one. Flip it to see the variant
#     actually split traffic.
#   * Content release — created `:open` with two items; releasing it (moving
#     it to `:scheduled`/live) is a separate operator action this script
#     deliberately doesn't take.

alias Example.Catalog
alias KilnCMS.Accounts
alias KilnCMS.Automation
alias KilnCMS.CMS
alias KilnCMS.Experiments

admin_email = System.get_env("ADMIN_EMAIL", "admin@kiln.test")

admin =
  case Accounts.get_user_by_email(admin_email, not_found_error?: false, authorize?: false) do
    {:ok, %{role: :admin} = user} -> user
    _ -> raise "No admin user for #{admin_email} — run priv/repo/seeds.exs first."
  end

tenant = Accounts.default_org_id()
opts = [actor: admin, tenant: tenant]

widget_pro =
  case Catalog.list_products!(%{}, opts) |> Enum.find(&(&1.slug == "widget-pro")) do
    %{} = product -> product
    nil -> raise "No \"widget-pro\" product — run example_import.exs first."
  end

demo_form =
  case CMS.get_active_form_by_slug("request-a-demo", opts) do
    {:ok, form} -> form
    _ -> raise "No \"request-a-demo\" form — run example_import.exs first."
  end

# --- Automation rule ---------------------------------------------------------
# `:suggest_tags` only ever suggests (an editor still accepts each one) — see
# `KilnCMS.Automation.Rule`'s moduledoc for why every reaction here is
# suggest-only rather than write-on-trigger.

rule_name = "Suggest tags on product review"

unless Enum.any?(Automation.list_rules!(%{}, opts), &(&1.name == rule_name)) do
  Automation.create_rule!(
    %{
      name: rule_name,
      trigger_event: :in_review,
      action: :suggest_tags,
      content_type: "product",
      # `:suggest_tags` only ever suggests (an editor still accepts each one)
      # — but it needs somewhere to send the suggestion.
      config: %{"to" => "editors@acme.example"}
    },
    opts
  )

  IO.puts("automation rule: created \"#{rule_name}\"")
else
  IO.puts("automation rule: \"#{rule_name}\" already exists")
end

# --- Webhook endpoint --------------------------------------------------------

webhook_url = "https://example.com/acme-webhook"

unless Enum.any?(CMS.list_webhook_endpoints!(%{}, opts), &(&1.url == webhook_url)) do
  CMS.create_webhook_endpoint!(%{url: webhook_url}, opts)
  IO.puts("webhook endpoint: created #{webhook_url}")
else
  IO.puts("webhook endpoint: #{webhook_url} already exists")
end

# --- Experiment (A/B test) on the Widget Pro product ------------------------

experiment_name = "Widget Pro headline test"

case Enum.find(Experiments.list_experiments!(%{}, opts), &(&1.name == experiment_name)) do
  %{} = experiment ->
    IO.puts("experiment: \"#{experiment_name}\" already exists (#{experiment.state})")

  nil ->
    experiment =
      Experiments.create_experiment!(
        %{
          name: experiment_name,
          content_type: "product",
          document_id: widget_pro.id,
          goal: :form_submission,
          goal_form_id: demo_form.id
        },
        opts
      )

    Experiments.create_variant!(
      %{experiment_id: experiment.id, name: "Control", patch: %{}, weight: 1, control: true},
      opts
    )

    Experiments.create_variant!(
      %{
        experiment_id: experiment.id,
        name: "Benefit-led headline",
        patch: %{"fields" => %{"title" => "Ship faster with Widget Pro"}},
        weight: 1,
        control: false
      },
      opts
    )

    Experiments.start_experiment!(experiment, opts)
    IO.puts("experiment: created and started \"#{experiment_name}\"")
end

# --- Content release ----------------------------------------------------------

release_name = "Fall product refresh"

case Enum.find(CMS.list_releases!(%{}, opts), &(&1.name == release_name)) do
  %{} = release ->
    IO.puts("release: \"#{release_name}\" already exists (#{release.state})")

  nil ->
    release =
      CMS.create_release!(
        %{name: release_name, description: "Widget Pro + Widget Case, bundled go-live."},
        opts
      )

    widget_case =
      Catalog.list_products!(%{}, opts) |> Enum.find(&(&1.slug == "widget-case"))

    for product <- [widget_pro, widget_case], product do
      CMS.add_release_item!(
        %{
          release_id: release.id,
          content_type: "product",
          content_id: product.id,
          action: :publish
        },
        opts
      )
    end

    IO.puts("release: created \"#{release_name}\" with 2 items")
end

IO.puts("Demo config finished.")
