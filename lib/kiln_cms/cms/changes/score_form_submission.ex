defmodule KilnCMS.CMS.Changes.ScoreFormSubmission do
  @moduledoc """
  Runs the spam-check registry (#477) against a fresh submission and stores
  the result: `spam_score` is always the summed weight of every flagged
  check, and `status` becomes `:spam` once that score reaches
  `Kiln.Forms.SpamCheck.threshold/0` — otherwise `:new`.

  Resolves the org's disallowed-keyword list (`KilnCMS.CMS.FormSpamSettings`)
  itself, `authorize?: false`: this runs on every public, anonymous
  submission — there is no actor to authorize an admin-only settings read
  against, the same reasoning `KilnCMS.CMS.Validations.RequiredConsent` gives
  for reading consents as the system.
  """
  use Ash.Resource.Change

  alias Kiln.Forms.SpamCheck
  alias Kiln.Forms.SpamCheck.Context
  alias Kiln.Forms.SpamCheck.Registry
  alias KilnCMS.CMS

  @impl true
  def change(changeset, _opts, _context) do
    data = Ash.Changeset.get_attribute(changeset, :data) || %{}
    locale = Ash.Changeset.get_attribute(changeset, :locale)
    fill_time_ms = Ash.Changeset.get_argument(changeset, :fill_time_ms)

    context =
      Context.new(data,
        locale: locale,
        keywords: keywords(changeset.tenant),
        facts: %{fill_time_ms: fill_time_ms}
      )

    outcomes = Registry.run(context)
    score = Registry.score(outcomes)
    status = if score >= SpamCheck.threshold(), do: :spam, else: :new

    changeset
    |> Ash.Changeset.force_change_attribute(:spam_score, score)
    |> Ash.Changeset.force_change_attribute(:status, status)
  end

  defp keywords(nil), do: []

  defp keywords(tenant) do
    case CMS.list_form_spam_settings(tenant: tenant, authorize?: false) do
      {:ok, [%{keywords: keywords} | _]} -> keywords
      _ -> []
    end
  end
end
