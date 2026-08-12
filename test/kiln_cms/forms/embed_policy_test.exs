defmodule KilnCMS.Forms.EmbedPolicyTest do
  @moduledoc """
  The org rung between a form's own `embed_origins` and the deployment's
  `EMBED_ORIGINS` (#1131).
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures

  alias KilnCMS.CMS
  alias KilnCMS.Forms.EmbedPolicy

  defp save!(attrs, org_id) do
    CMS.save_site_embed_settings!(attrs, authorize?: false, tenant: org_id)
  end

  describe "org_default/1" do
    test "nil org id asks nothing and answers nil" do
      assert EmbedPolicy.org_default(nil) == nil
    end

    test "an org with no configured row answers nil" do
      org_id = org("epol-none").id
      assert EmbedPolicy.org_default(org_id) == nil
    end

    test "an org that saved an explicit close answers []" do
      org_id = org("epol-closed").id
      save!(%{embed_origins: []}, org_id)

      assert EmbedPolicy.org_default(org_id) == []
    end

    test "an org with a saved allowlist answers it" do
      org_id = org("epol-list").id
      save!(%{embed_origins: ["https://partner.test"]}, org_id)

      assert EmbedPolicy.org_default(org_id) == ["https://partner.test"]
    end

    # A row can exist with `embed_origins: nil` — the same "not yet decided"
    # state a fresh row starts in before an admin picks a mode — and it must
    # answer the same as no row at all.
    test "a row whose embed_origins is nil answers nil, same as no row" do
      org_id = org("epol-row-nil").id
      save!(%{embed_origins: nil}, org_id)

      assert EmbedPolicy.org_default(org_id) == nil
    end
  end

  describe "effective/1" do
    test "nil form asks nothing and answers nil" do
      assert EmbedPolicy.effective(nil) == nil
    end

    test "a form with its own list is unchanged, org is never consulted" do
      form = %{embed_origins: ["https://form-own.test"], org_id: org("epol-eff-own").id}
      assert EmbedPolicy.effective(form) == form
    end

    test "a form's own explicit close ([]) is unchanged, org is never consulted" do
      form = %{embed_origins: [], org_id: org("epol-eff-close").id}
      assert EmbedPolicy.effective(form) == form
    end

    test "a form with no list of its own inherits its org's configured default" do
      org_id = org("epol-eff-inherit").id
      save!(%{embed_origins: ["https://org-default.test"]}, org_id)

      form = %{embed_origins: nil, org_id: org_id}

      assert EmbedPolicy.effective(form) == %{
               embed_origins: ["https://org-default.test"],
               org_id: org_id
             }
    end

    test "a form with no list of its own, and an org with none configured, is unchanged" do
      org_id = org("epol-eff-neither").id
      form = %{embed_origins: nil, org_id: org_id}

      assert EmbedPolicy.effective(form) == form
    end

    # Refused, not defaulted — the same rule `KilnCMSWeb.Embed.own_origins/1`
    # enforces. A narrowed read must not silently regain a policy the form (or
    # now the org) had deliberately narrowed away from.
    test "a form whose embed_origins was not selected is passed through untouched" do
      form = %{embed_origins: %Ash.NotLoaded{}, org_id: org("epol-eff-notloaded").id}
      assert EmbedPolicy.effective(form) == form
    end
  end
end
