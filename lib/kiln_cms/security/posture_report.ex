defmodule KilnCMS.Security.PostureReport do
  @moduledoc """
  The Security posture report (#2252) as one Ash action, `:run`, so the
  console page asks for it through a policy like everything else.

  No data layer: the action computes a fresh `KilnCMS.Security.Posture.Report`
  and nothing is stored (see `KilnCMS.Security.Posture`).

  ## Who may run it, and what they get

  An administrator of the request's site (`KilnCMS.CMS.Checks.OrgAdmin`).
  The site is the action's **tenant**, never an argument: with no tenant the
  site is the default one, which an administrator of another site is refused
  on. Every caller gets the site's checks (`:site`); a platform administrator
  (effective platform role `:admin`) also gets the deployment's
  (`:deployment`), which describe the whole installation.

  At most `KilnCMS.Security.Posture.max_per_org/0` reports of one site run at
  once on a node; beyond that the action answers
  `KilnCMS.Security.Errors.PostureBusy` (see `KilnCMS.Security.Posture.with_slot/2`).
  """
  use Ash.Resource,
    domain: KilnCMS.Security,
    authorizers: [Ash.Policy.Authorizer]

  alias KilnCMS.Accounts.RoleGrant
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
        scopes =
          if RoleGrant.effective_role(context.actor) == :admin,
            do: [:site, :deployment],
            else: [:site]

        org_id = Scoping.subject_org_id(input)

        case Posture.with_slot(org_id, fn ->
               Posture.report(org_id, scopes, locale: input.arguments[:locale])
             end) do
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
    policy action(:run) do
      authorize_if KilnCMS.CMS.Checks.OrgAdmin
    end
  end
end
