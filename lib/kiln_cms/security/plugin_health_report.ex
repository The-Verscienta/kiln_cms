defmodule KilnCMS.Security.PluginHealthReport do
  @moduledoc """
  The cached plugin health report (#2571) as an Ash action, so the monitoring
  endpoint (`GET /api/security/plugin-health`) reads it through a policy like
  everything else.

    * `:cached` answers `Kiln.Plugins.Health.cached/0`: a
      `Kiln.Plugins.Health.Report`, or `nil` when this node holds no fresh
      check. It **never** makes a request and never starts one, not even in the
      background (`Kiln.Plugins.Health.warm/0` is not called): reading health
      must not tell hex.pm or the notices feed anything. A disabled check and
      a deployment with nothing to check answer a report, since neither needs
      a request.

  No data layer: nothing is stored here (the cache is the health check's,
  per node).

  ## Who may read it

  A platform administrator (`KilnCMS.Accounts.Checks.PlatformAdmin`: an
  effective platform role of `:admin`, so a live temporary grant counts and
  an expired one does not), unless they authenticated with a `:draft_write`
  API key, which may draft and nothing else
  (`KilnCMS.Accounts.Checks.DraftWriteKey`). A site's administrator is
  refused: which plugins are installed, and what is wrong with them, describe
  the whole deployment, as on System → Plugins. The report is the same on
  every site, so the action takes no tenant.
  """
  use Ash.Resource,
    domain: KilnCMS.Security,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    action :cached, :struct do
      description "The installed plugins' health from this node's cache, or nil when it " <>
                    "holds no fresh check. Never makes a request."

      constraints instance_of: Kiln.Plugins.Health.Report
      allow_nil? true

      run fn _input, _context -> {:ok, Kiln.Plugins.Health.cached()} end
    end
  end

  policies do
    # Deployment-wide data: platform administrators only, as on System →
    # Plugins. A site administrator is not enough.
    policy action(:cached) do
      # A drafts-only key may draft and nothing else (#2273, DraftWriteKey's
      # moduledoc), whoever owns it.
      forbid_if KilnCMS.Accounts.Checks.DraftWriteKey
      authorize_if KilnCMS.Accounts.Checks.PlatformAdmin
    end
  end
end
