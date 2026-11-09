defmodule KilnCMS.CMS.Changes.ScoreFormSubmission do
  @moduledoc """
  Runs the spam-check registry (#477) against a fresh submission and stores
  the result: `spam_score` is always the summed weight of every flagged
  check, and `status` becomes `:spam` once that score reaches
  `Kiln.Forms.SpamCheck.threshold/0` — otherwise `:new`.

  Resolves the org's disallowed-keyword list (`KilnCMS.CMS.FormSpamSettings`)
  itself, as `KilnCMS.CMS.Bookkeeping.system/0` (#1659): this runs on every
  public, anonymous submission — there is no actor to authorize an admin-only
  settings read against. `FormSpamSettings` admits the system actor to `read`
  alone.

  The read fails CLOSED. A refused read filters to "no settings row", and an
  error used to answer `[]` too — either way the keyword check silently
  stopped flagging anything. A refusal or a read error now raises, so the
  submission is refused rather than stored unscored.

  ## Human verification (#2249)

  The create's `challenge` argument (`KilnCMS.Challenge.Gate.form/3`) is
  stored on the attribute of the same name and offered to the checks as the
  `challenge` fact. Every outcome but `:passed` *holds* the submission: the
  score is raised by the threshold, so it lands in Spam with nobody mailed and
  no webhook fired, but the data is kept for an admin to review. Done here
  rather than as a registry check so a site cannot unregister or reweigh it.
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
    challenge = Ash.Changeset.get_argument(changeset, :challenge)

    context =
      Context.new(data,
        locale: locale,
        keywords: keywords(changeset.tenant),
        facts: %{fill_time_ms: fill_time_ms, challenge: challenge}
      )

    outcomes = Registry.run(context)
    score = Registry.score(outcomes) + held_weight(challenge)
    status = if score >= SpamCheck.threshold(), do: :spam, else: :new

    changeset
    |> Ash.Changeset.force_change_attribute(:challenge, challenge)
    |> Ash.Changeset.force_change_attribute(:spam_score, score)
    |> Ash.Changeset.force_change_attribute(:status, status)
  end

  defp held_weight(challenge) when challenge in [nil, :passed], do: 0
  defp held_weight(_held), do: SpamCheck.threshold()

  defp keywords(nil), do: []

  defp keywords(tenant) do
    CMS.list_form_spam_settings!(
      actor: KilnCMS.CMS.Bookkeeping.system(),
      authorize_with: :error,
      tenant: tenant
    )
    |> case do
      [%{keywords: keywords} | _] -> keywords
      [] -> []
    end
  end
end
