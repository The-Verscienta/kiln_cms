defmodule KilnCMS.CMS.SiteBotBudgets do
  @moduledoc """
  A site's per-class delivery ceilings (#2243): how much of the `:delivery`
  rate-limit budget a search engine, an AI crawler, a declared bot or a client
  with no user agent may spend from one address, as a percentage of what a
  browser gets. `KilnCMS.BotClass` decides the class; `KilnCMS.BotBudgets`
  resolves the ceiling; `KilnCMSWeb.Plugs.RateLimit` applies it.

  Each column is nullable: `nil` inherits the operator's value
  (`KILN_BOT_BUDGET_*_PERCENT`, or the built-in default), so a site that sets
  only `empty_percent` keeps the operator's values for the other three. There
  is no browser column: the browser ceiling is the `:delivery` limit itself.

  ## The operator owns capacity, a site may only tighten

  The `KilnCMS.Forms.EmbedCeiling` precedent (#1133): the deployment's value is
  the most a site may ask for. A write that **changes** a column to more than
  the operator's value is refused (`KilnCMS.CMS.Validations.BotBudgetCeiling`),
  and the resolver clamps a stored value at read time, so a row written before
  the operator lowered their value cannot keep a class above it.

  One row per organization, admin-only to read and write, created lazily by
  `:save`. Delivery reads it as `KilnCMS.OrgSettings.system(:bot_budgets)`
  (`system_actions:` admits `read` and nothing else), cached per org and busted
  after commit on every write.
  """
  use KilnCMS.CMS.OrgSettings,
    table: "site_bot_budgets",
    accept: [:search_engine_percent, :ai_crawler_percent, :declared_bot_percent, :empty_percent],
    read: :admin,
    admin_columns: [
      :search_engine_percent,
      :ai_crawler_percent,
      :declared_bot_percent,
      :empty_percent,
      :updated_at
    ],
    system_actions: [read: :bot_budgets]

  # After COMMIT, like every delivery-facing settings bust — see the change.
  changes do
    change KilnCMS.CMS.Changes.BustBotBudgets, on: [:create, :update, :destroy]
  end

  validations do
    validate KilnCMS.CMS.Validations.BotBudgetCeiling
  end

  attributes do
    # Percent of the `:delivery` limit, 1-1000. No 0: refusing a class outright
    # is the IP block list's job (#2242), or a robots.txt served in front of Kiln, not a rate limit's.
    attribute :search_engine_percent, :integer do
      allow_nil? true
      public? true
      constraints min: 1, max: 1000
    end

    attribute :ai_crawler_percent, :integer do
      allow_nil? true
      public? true
      constraints min: 1, max: 1000
    end

    attribute :declared_bot_percent, :integer do
      allow_nil? true
      public? true
      constraints min: 1, max: 1000
    end

    attribute :empty_percent, :integer do
      allow_nil? true
      public? true
      constraints min: 1, max: 1000
    end
  end
end
