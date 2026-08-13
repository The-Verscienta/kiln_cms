defmodule KilnCMS.Automation.Validations.ActionConfig do
  @moduledoc """
  Validates a rule's `config` against the `action` that will read it (#944).

  `config` is a free `:map` typed into a JSON textarea, and every reaction read
  it defensively — a missing or misspelled key produced a `Logger.warning` and
  `:ok`. So a rule could be saved, listed as **enabled**, and render green in
  `/editor/automation` while being structurally incapable of doing anything,
  forever, with the only evidence in a server log the admin who typed it is not
  reading.

  Two shapes made that more than theoretical:

    * **`"allow_egress": "true"`** — the *string*. Every other key in that
      textarea (`to`, `subject`, `topic`, `segment_id`) is a string, so this is
      the natural mistake. `:suggest_metadata` requires the JSON boolean and
      correctly fails closed, which means the rule looks configured and emails
      nothing.
    * **A missing `to`** on `:send_email` or on any of the four intelligence
      reactions, all of which deliver by email and nothing else.

  ## `deliver_as` (#946)

  The four intelligence reactions no longer only email. `deliver_as` picks the
  landing place — `"email"` (the default, so an existing rule with no
  `deliver_as` key keeps working unchanged), `"comment"`, or `"task"` — and
  what else is required depends on which: `"email"` still needs `to`;
  `"task"` needs `assignee` (and takes an optional `due_in_days`); `"comment"`
  needs nothing further. That is a requirement conditional on a sibling key's
  *value*, which the required/optional lists above can't express on their own
  — a shape may carry a `:required_when` tag naming a resolver
  (`deliver_as_required/1`, the only one there is) that `check/2` calls with
  the config, after the unconditional `:required` list, to get the additional
  fields the config as given needs. Deliberately narrow: this is the one
  shape that needs it, not a general conditional-validation language.

  ## Why unknown keys are refused, not ignored

  A typo is the failure this exists to catch, and an ignored key is a typo that
  survives the form. `%{"recipient" => "team@example.com"}` on `:send_email` is
  a rule that will never send, and it reads as configured. Refusing an
  unrecognized key turns that into a message beside the field.

  The cost is that adding a config key to a reaction means adding it here too.
  That is the intended coupling, and it is one-way: `@shapes` is the single
  description of what a reaction accepts, and `KilnCMSWeb.AutomationLive`
  renders its per-action key hint by *reading* `shapes/0` rather than by
  restating it. A hand-maintained list of the same keys beside the field would
  be a doc that drifts from its own enforcement — the shape of the bug this
  validation exists to end.
  """
  use Ash.Resource.Validation

  alias KilnCMS.Social.Account

  # The four intelligence reactions share this whole optional set — every key
  # any `deliver_as` value could need — because `check/2`'s `unknown/2` refuses
  # anything outside `required ++ optional` regardless of which `deliver_as`
  # is chosen, and it has no visibility into `:required_when` (see
  # `deliver_as_required/1` below) when computing that combined set.
  @deliver_as_optional [
    {"deliver_as", :deliver_as},
    {"to", :email},
    {"assignee", :uuid},
    {"due_in_days", :integer}
  ]

  # `deliver_as` (#946): which fields the four intelligence reactions need
  # beyond the base shape depends on where the finding is going. No key at all
  # reads as `"email"` — the pre-#946 behaviour every existing rule already
  # relies on — so an absent `deliver_as` still needs `to`, exactly as before.
  # Defined ahead of `@shapes` below (a module attribute is evaluated where it
  # appears, not deferred like a function body) so `&deliver_as_required/1`
  # can capture it.
  defp deliver_as_required(config) do
    case Map.get(config, "deliver_as", "email") do
      "email" -> [{"to", :email}]
      "task" -> [{"assignee", :uuid}]
      "comment" -> []
      # Not a recognized value — `typed/2` reports it against `:deliver_as`
      # once the value is checked; nothing extra to require here.
      _other -> []
    end
  end

  # One entry per action kind. `:required` must be present and well-typed;
  # `:optional` must be well-typed when present; anything else is refused.
  #
  # `:email` and `:provider` are deliberately shallow checks. This is a
  # configuration form, not an address verifier — the value of catching
  # "team at example.com" here is that it is caught at all, and a stricter rule
  # would start refusing addresses that work.
  @shapes %{
    send_email: %{
      required: [{"to", :email}],
      optional: [{"subject", :template}, {"body", :template}]
    },
    broadcast: %{required: [], optional: [{"topic", :string}]},
    invalidate_cache: %{required: [], optional: []},
    reindex: %{required: [], optional: []},
    newsletter: %{
      required: [],
      optional: [{"segment_id", :string}, {"subject", :template}]
    },
    social_post: %{
      required: [{"provider", :provider}],
      optional: [{"template", :template}]
    },
    flag_duplicates: %{
      required: [],
      optional: @deliver_as_optional,
      required_when: :deliver_as
    },
    suggest_tags: %{
      required: [],
      optional: @deliver_as_optional,
      required_when: :deliver_as
    },
    suggest_links: %{
      required: [],
      optional: @deliver_as_optional,
      required_when: :deliver_as
    },
    suggest_metadata: %{
      required: [],
      optional: [{"allow_egress", :boolean} | @deliver_as_optional],
      required_when: :deliver_as
    }
  }

  @doc """
  What one action kind accepts: `%{required: [...], optional: [...]}`.

  Public so the admin UI can describe a reaction from the same source that
  enforces it, and so a test can assert every kind in
  `KilnCMS.Automation.Rule.action_kinds/0` has an entry.
  """
  @spec shape(atom()) :: %{required: list(), optional: list()} | nil
  def shape(action), do: Map.get(@shapes, action)

  @doc "The shape table, keyed by action kind."
  @spec shapes() :: map()
  def shapes, do: @shapes

  @impl true
  def validate(changeset, _opts, _context) do
    action = Ash.Changeset.get_attribute(changeset, :action)
    config = Ash.Changeset.get_attribute(changeset, :config) || %{}

    case shape(action) do
      # No action yet, or one with no entry. `action`'s own `one_of` constraint
      # reports the second case; duplicating it here would report it twice.
      nil -> :ok
      shape -> check(shape, config)
    end
  end

  @impl true
  def describe(_opts), do: [message: "is not valid for this action", vars: []]

  defp check(shape, config) when is_map(config) do
    known = Enum.map(shape.required ++ shape.optional, &elem(&1, 0))
    required = shape.required ++ conditional_required(shape, config)

    with :ok <- missing(required, config),
         :ok <- unknown(known, config) do
      typed(shape.required ++ shape.optional, config)
    end
  end

  # A non-map `config` can't reach here through the resource (the attribute is
  # `:map`), but a validation that assumes its input is a courtesy to nobody.
  defp check(_shape, _config), do: error("must be a JSON object.")

  defp conditional_required(%{required_when: :deliver_as}, config),
    do: deliver_as_required(config)

  defp conditional_required(_shape, _config), do: []

  defp missing(required, config) do
    case Enum.find(required, fn {key, _type} -> blank?(Map.get(config, key)) end) do
      nil -> :ok
      {key, _type} -> error("is missing `#{key}`, which this action needs to do anything.")
    end
  end

  defp unknown(known, config) do
    case Enum.find(Map.keys(config), &(&1 not in known)) do
      nil ->
        :ok

      key ->
        error(
          "has no `#{key}` for this action. It accepts: #{list(known)}. " <>
            "An unrecognized key is usually a typo, and a rule saved with one " <>
            "looks configured while doing nothing."
        )
    end
  end

  defp typed(fields, config) do
    fields
    |> Enum.reject(fn {key, _type} -> is_nil(Map.get(config, key)) end)
    |> Enum.find_value(:ok, fn {key, type} ->
      value = Map.get(config, key)

      unless well_typed?(type, value) do
        error("`#{key}` #{expectation(type)}, got #{inspect(value)}.")
      end
    end)
  end

  # A JSON boolean, never the string "true". Coercing it here would be the
  # wrong kind of generous: `allow_egress` is the switch that permits an
  # unattended reaction to send page bodies off-site, and "what counts as true"
  # is not a thing to guess at on an egress gate. `RuleWorker` already fails
  # closed on it; this makes the near-miss visible where it was typed.
  defp well_typed?(:boolean, value), do: is_boolean(value)
  defp well_typed?(:string, value), do: is_binary(value) and String.trim(value) != ""
  defp well_typed?(:template, value), do: well_typed?(:string, value)

  defp well_typed?(:email, value) do
    well_typed?(:string, value) and Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/u, value)
  end

  defp well_typed?(:provider, value) do
    well_typed?(:string, value) and Enum.any?(Account.providers(), &(to_string(&1) == value))
  end

  defp well_typed?(:deliver_as, value) do
    well_typed?(:string, value) and value in ~w(email comment task)
  end

  # A uuid string, shallow-checked (format only) the same way `:email` is —
  # `assignee` naming a user who exists and is an editor/admin is
  # `KilnCMS.CMS.Validations.AssigneeIsEditor`'s job, at task-assignment time.
  defp well_typed?(:uuid, value) do
    well_typed?(:string, value) and match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp well_typed?(:integer, value), do: is_integer(value) and value > 0

  defp expectation(:boolean), do: "must be the JSON boolean true or false (not a string)"
  defp expectation(:email), do: "must be an email address"
  defp expectation(:provider), do: "must be one of #{list(Account.providers())}"
  defp expectation(:deliver_as), do: "must be one of email, comment, task"
  defp expectation(:uuid), do: "must be a uuid"
  defp expectation(:integer), do: "must be a positive whole number"
  defp expectation(_type), do: "must be a non-empty string"

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp list(values), do: values |> Enum.map_join(", ", &to_string/1)

  defp error(message) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :config,
       message: "Action config " <> message
     )}
  end
end
