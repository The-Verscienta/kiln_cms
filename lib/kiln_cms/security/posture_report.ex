defmodule KilnCMS.Security.PostureReport do
  @moduledoc """
  The Security posture report (#2252) as Ash actions, so every reader asks
  for it through a policy like everything else:

    * `:run`, the console page's: a fresh `KilnCMS.Security.Posture.Report`
      in the reader's locale, details included. Never cached ("Run checks
      again" means again).
    * `:snapshot`, monitoring's (`GET /api/security/posture`, #2521): the
      same report in English, without any result's details, reused for
      30 seconds per site and scope set (`KilnCMS.Security.Posture.snapshot/2`).

  No data layer: nothing is stored (see `KilnCMS.Security.Posture`).

  ## Who may run it, and what they get

  An administrator of the request's site (`KilnCMS.CMS.Checks.OrgAdmin`),
  on either action, unless they authenticated with a `:draft_write` API key,
  which may draft and nothing else (`KilnCMS.Accounts.Checks.DraftWriteKey`).
  The site is the action's **tenant**, never an argument: with no tenant the
  site is the default one, which an administrator of another site is refused
  on. Every caller gets the site's checks (`:site`); a platform administrator
  (effective platform role `:admin`) also gets the deployment's
  (`:deployment`), which describe the whole installation
  (`KilnCMS.Security.Posture.scopes_for/1`).

  At most `KilnCMS.Security.Posture.max_per_org/0` reports of one site run at
  once on a node; beyond that the action answers
  `KilnCMS.Security.Errors.PostureBusy` (see `KilnCMS.Security.Posture.with_slot/2`).
  """
  use Ash.Resource,
    domain: KilnCMS.Security,
    authorizers: [Ash.Policy.Authorizer]

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.Security.Posture

  actions do
    action :run, :struct do
      description "The site's (and, for a platform admin, the deployment's) security posture."
      constraints instance_of: Posture.Report

      argument :locale, :string do
        description "The reader's locale, handed to every check (default \"en\")."
        constraints max_length: 35
      end

      run fn input, context ->
        scopes = Posture.scopes_for(context.actor)
        org_id = Scoping.subject_org_id(input)

        case Posture.with_slot(org_id, fn ->
               Posture.report(org_id, scopes, locale: input.arguments[:locale])
             end) do
          {:ok, report} -> {:ok, report}
          {:error, :busy} -> {:error, KilnCMS.Security.Errors.PostureBusy.exception([])}
        end
      end
    end

    action :snapshot, :struct do
      description "The site's (and, for a platform admin, the deployment's) security posture " <>
                    "for monitoring: in English, without details, reused for 30 seconds per " <>
                    "site and scope set."

      constraints instance_of: Posture.Report

      run fn input, context ->
        case Posture.snapshot(Scoping.subject_org_id(input), Posture.scopes_for(context.actor)) do
          {:ok, report} -> {:ok, report}
          {:error, :busy} -> {:error, KilnCMS.Security.Errors.PostureBusy.exception([])}
        end
      end
    end
  end

  policies do
    # The site's own administrators, platform administrators included (they
    # are an administrator of every site). What a platform administrator sees
    # beyond the site is decided in the action, from the same actor.
    policy action([:run, :snapshot]) do
      # A drafts-only key may draft and nothing else (#2273, DraftWriteKey's
      # moduledoc). Minting already requires a viewer-tier owner; this holds
      # if the owner is made an administrator later.
      forbid_if KilnCMS.Accounts.Checks.DraftWriteKey
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end
end
