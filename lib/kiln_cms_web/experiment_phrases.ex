defmodule KilnCMSWeb.ExperimentPhrases do
  @moduledoc """
  The translated sentence for each experiment health reason (#1008, #1087).

  `KilnCMS.Experiments.blocked_reason/1` and `anomaly_reason/2` each return a
  `{reason_atom, english_sentence}`; the sentence is for the terminal
  (`mix kiln.experiment`), and every web surface phrases the **atom** here so
  it translates. One list, used by `KilnCMSWeb.OverviewLive`'s admin strip and
  `KilnCMSWeb.ExperimentsLive`'s results panel — the two used to be one
  private list in the overview, and the panel would have grown its own.

  Deliberately total: a reason added to `Health` and not here must not crash
  a page, which is a worse outcome than a vaguer sentence.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  @doc "Why a running experiment cannot convert, as a clause that follows the name."
  @spec blocked_headline(atom()) :: String.t()
  def blocked_headline(:sticky_off),
    do: gettext("its goal converts on a later page, and sticky assignment is off")

  def blocked_headline(:no_goal_form), do: gettext("no goal form is set")
  def blocked_headline(:goal_form_missing), do: gettext("its goal form has been deleted")
  def blocked_headline(:no_target), do: gettext("no goal document is set")
  def blocked_headline(:no_goal_funnel), do: gettext("no goal funnel is set")

  def blocked_headline(:goal_is_self),
    do: gettext("its goal document is the experimented document itself")

  def blocked_headline(:goal_type_unknown),
    do: gettext("its goal content type is not a type on this site")

  def blocked_headline(:goal_document_missing),
    do: gettext("its goal document has been deleted")

  def blocked_headline(:funnel_ends_here),
    do: gettext("its funnel now ends on the experimented document itself")

  def blocked_headline(:funnel_target_missing),
    do: gettext("its funnel no longer resolves to a document")

  def blocked_headline(:document_missing),
    do: gettext("the document under test has been deleted")

  def blocked_headline(:document_unpublished),
    do: gettext("the document under test is not published, so no arm is served")

  def blocked_headline(:goal_document_unpublished),
    do: gettext("its goal document is not published")

  def blocked_headline(:goal_form_inactive),
    do: gettext("its goal form is no longer accepting submissions")

  # "could not be read" is deliberately NOT "has been deleted": a pool timeout
  # and a deletion are the same tuple at the call site, and telling an admin a
  # form was removed sends them to restore something nobody touched.
  def blocked_headline(:goal_unreadable),
    do: gettext("its goal could not be read — this may be temporary")

  def blocked_headline(:unknown_goal),
    do: gettext("its goal is one this version cannot check")

  # Deliberately total: a reason added to `Health` and not here would otherwise
  # crash the overview, which is a worse outcome than a vaguer sentence.
  def blocked_headline(_other), do: gettext("its goal can no longer be reached")

  @doc "Why a variant's counters are not to be trusted (#1007)."
  @spec anomaly_headline(atom()) :: String.t()
  def anomaly_headline(:conversions_exceed_impressions),
    do: gettext("more conversions than impressions — these counters are not trustworthy")

  def anomaly_headline(_other), do: gettext("these counters look wrong")
end
