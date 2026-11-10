defmodule KilnCMSWeb.WorkflowMessages do
  @moduledoc """
  Flash copy for the content workflow transitions — `submit`, `return`,
  `publish`, `unpublish`, `archive`, `unarchive` — shared by the content list
  (`KilnCMSWeb.EditorLive`) and the content editor
  (`KilnCMSWeb.ContentEditorLive`), so the two surfaces cannot drift apart.

  A failure is described by the error the transition actually returned, never
  by which button was pressed. Only an `Ash.Error.Forbidden` is about the
  actor's role; the Publish, Approve and Return buttons are rendered for admins
  alone, so keying the copy on the verb told an admin whose publish hit a
  publish gate (claim checking, alt text, required consent) that publishing
  "requires an admin approval" — false for them, and it hid the gate's own
  sentence, which is the only thing they could act on. A lost race against a
  colleague's transition (`NoMatchingTransition` / `StaleRecord`, see
  `KilnCMSWeb.AshStateMachineErrors`) is said as such.

  ## Which refusal sentence (#2473)

  A `Forbidden` does not say which policy refused, so `refusal/2` asks the
  same questions the content policies ask, at the moment of the refusal (the
  tier through `Scoping.effective_tier/2`, which applies a temporary grant
  against the clock now, and the site's switch read uncached), rather than
  trusting what the LiveView assigned at mount:

    1. an editor refused `return` is told it is an admin's step — it is
       (`OrgAdmin` alone), whatever the switch or their scope says;
    2. an editor whose `editable_types` scope leaves out this content type is
       told so, for the update transitions that scope gates
       (`KilnCMS.CMS.Checks.EditableContentType`) — the publish switch would
       not have helped them. Not for the trash: a destroy is admin-only, so
       a wider scope would not help either;
    3. an editor on a site where publishing needs an admin, refused a publish,
       unpublish or archive (`KilnCMS.CMS.Checks.EditorMayPublish`), is told
       an admin does it;
    4. everyone else — a viewer, an admin, an editor refused for any other
       reason — gets the plain sentence. Saying "only an admin" to them was
       false, or no help.
  """

  use Gettext, backend: KilnCMSWeb.Gettext

  import KilnCMSWeb.CoreComponents, only: [ash_error_message: 2, state_label: 1]

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.EditorialSettings

  @typedoc """
  Who was refused, where, and on what: `:actor`, `:org` (an org id or
  `%Organization{}`; `nil` is the default org) and `:resource` (the content
  record or its resource module; leave it out when there is no one record).
  """
  @type context :: [
          actor: map() | nil,
          org: struct() | String.t() | nil,
          resource: atom() | struct()
        ]

  @typedoc "Why a refusal happened, as far as the copy needs to know."
  @type refusal :: :out_of_scope | :needs_publisher | :needs_admin | :not_permitted

  # The transitions `EditorMayPublish` gates (and so the switch can open).
  @publish_gated ~w(publish unpublish archive)

  # Destroys: admin-only for everyone (`forbid_if always()` below the admin
  # bypass), so `editable_types` — which gates creates and updates — is never
  # their reason.
  @destroys ~w(trash delete)

  @doc "The success flash for `action`, given the state the record landed in."
  @spec success(String.t(), atom()) :: String.t()
  def success("submit", _state),
    do: gettext("Sent for review — an admin will publish when ready.")

  def success(_action, state), do: gettext("Updated to %{state}.", state: state_label(state))

  @doc "The failure flash for `action`, chosen from the error it returned."
  @spec error(String.t(), term(), context()) :: String.t()
  def error(action, error, context) do
    cond do
      forbidden?(error) ->
        forbidden(action, context)

      state_conflict?(error) ->
        gettext("Someone else changed this item's status first — reload to see where it stands.")

      is_exception(error) ->
        ash_error_message(error, fallback: gettext("That action isn't allowed right now."))

      true ->
        gettext("That action isn't allowed right now.")
    end
  end

  @doc "Why `action` was refused to the actor in `context` — see `refusal/2`."
  @spec forbidden(String.t(), context()) :: String.t()
  def forbidden(action, context), do: refusal_message(refusal(action, context), action)

  @doc """
  The sentence for a refusal `refusal/2` already decided — for a caller that
  branched on it first, so the decision (and its settings read) runs once.
  """
  @spec refusal_message(refusal(), String.t()) :: String.t()
  def refusal_message(refusal, action) do
    case refusal do
      :out_of_scope ->
        gettext("You can't edit this content type.")

      :needs_publisher ->
        needs_publisher(action)

      :needs_admin ->
        gettext("Only an admin can return content to draft.")

      :not_permitted ->
        gettext("You don't have permission to do that.")
    end
  end

  @doc """
  Which refusal `action` met, decided now from the actor's effective tier on
  the org, their content-type scope and the site's publish switch — see the
  moduledoc. A caller with its own wording for a gated write (the calendar's
  date moves) branches on this.
  """
  @spec refusal(String.t(), context()) :: refusal()
  def refusal(action, context) do
    actor = Keyword.get(context, :actor)
    org_id = Scoping.subject_org_id(Keyword.get(context, :org))

    cond do
      Scoping.effective_tier(actor, org_id) != :editor ->
        :not_permitted

      action == "return" ->
        :needs_admin

      action not in @destroys and
          out_of_scope?(actor, org_id, Keyword.get(context, :resource)) ->
        :out_of_scope

      action in @publish_gated and not EditorialSettings.editors_can_publish?(org_id) ->
        :needs_publisher

      true ->
        :not_permitted
    end
  end

  defp needs_publisher("publish"),
    do: gettext("Only an admin can publish. Submit the draft for review instead.")

  # Taking content down needs the publish permission (#2134).
  defp needs_publisher("unpublish"),
    do: gettext("Only an admin can unpublish content on this site.")

  defp needs_publisher("archive"), do: gettext("Only an admin can archive content on this site.")

  defp out_of_scope?(_actor, _org_id, nil), do: false

  defp out_of_scope?(actor, org_id, %resource{}), do: out_of_scope?(actor, org_id, resource)

  # The question `KilnCMS.CMS.Checks.EditableContentType` asks, of a query on
  # the same org: `permitted?/4` reads the org off a query or changeset, and
  # resolves a bare org id against the default org instead.
  defp out_of_scope?(actor, org_id, resource) when is_atom(resource) do
    subject = resource |> Ash.Query.new() |> Ash.Query.set_tenant(org_id)

    not Scoping.permitted?(
      actor,
      subject,
      :editable_types,
      ContentTypes.scope_group_name(resource)
    )
  end

  defp forbidden?(error), do: match?(%Ash.Error.Forbidden{}, error_class(error))

  defp state_conflict?(error) do
    error
    |> error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(fn
      %AshStateMachine.Errors.NoMatchingTransition{} -> true
      %Ash.Error.Changes.StaleRecord{} -> true
      _ -> false
    end)
  end

  defp error_class(error) when is_exception(error), do: Ash.Error.to_error_class(error)
  defp error_class(_error), do: %{}
end
