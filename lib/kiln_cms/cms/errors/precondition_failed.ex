defmodule KilnCMS.CMS.Errors.PreconditionFailed do
  @moduledoc """
  A write refused because the record is no longer the version the client said
  it was writing from — an `If-Match` that matched no current `ETag`, or an
  `expected_lock_version` that is not the row's `lock_version`
  (`KilnCMS.CMS.Changes.CheckExpectedVersion`).

  Its own type rather than `Ash.Error.Changes.StaleRecord`, which the workflow
  transitions already raise for a lost state compare-and-swap and which the
  headless surfaces report as a 409 (`KilnCMSWeb.AshStateMachineErrors`). This
  one is the client's own precondition failing, which HTTP spells 412, and it
  carries the current version so the client can re-read and retry without a
  second round trip to find out what changed.
  """
  use Splode.Error, fields: [:lock_version, :state], class: :invalid

  @impl true
  def message(%{lock_version: nil}),
    do: "this content no longer exists in the version you are writing from"

  def message(%{lock_version: version, state: state}) do
    "this content was changed since you read it — it is now version #{version} " <>
      "(#{state}); re-read it and retry"
  end
end
