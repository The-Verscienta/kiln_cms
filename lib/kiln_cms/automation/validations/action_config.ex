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
  (`deliver_as_required/1`, reading the `@deliver_as` table — the only
  one there is) that `check/2` calls with
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
  description of what a reaction accepts, and the admin form
  (`KilnCMSWeb.AutomationLive.ConfigFields`) generates one input per key by
  *reading* `shapes/0` and `required_keys/2` rather than by restating them. A
  hand-maintained list of the same keys beside the field would be a doc that
  drifts from its own enforcement — the shape of the bug this validation
  exists to end. The form adds only labels and widgets, keyed by the names
  this table declares, and a test fails when a key here has none.

  The validation stays strict even though the form now produces well-typed
  values: API clients and seeds still write `config` as raw JSON, and
  `"allow_egress": "true"` is as easy a mistake there as it ever was.
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

  # `deliver_as` (#946): where an intelligence reaction's finding lands, and
  # the keys each landing place reads — `:required` ones must be present,
  # `:uses` are read when present. The one description of the axis: the
  # validation derives what's required from it, and the admin form
  # (`KilnCMSWeb.AutomationLive.ConfigFields`) derives which values to offer
  # and which fields to show from it, so a new landing place or key added here
  # reaches both. A keyword list, not a map, because its order is the order
  # the form offers the values in.
  @deliver_as [
    email: %{required: ["to"], uses: ["to"]},
    comment: %{required: [], uses: []},
    task: %{required: ["assignee"], uses: ["assignee", "due_in_days"]}
  ]
  @deliver_as_values Enum.map(@deliver_as, fn {value, _} -> to_string(value) end)

  # No key at all reads as `"email"` — the pre-#946 behaviour every existing
  # rule already relies on — so an absent `deliver_as` still needs `to`,
  # exactly as before.
  #
  # `Map.get(config, "deliver_as", "email")` would only default on an *absent*
  # key — an explicit `"deliver_as": null` (a JSON author's natural way to
  # write "use the default") stores as a present key with a `nil` value and
  # would require nothing, silently bypassing the `to` check every other
  # spelling of "email" gets.
  defp current_deliver_as(config), do: Map.get(config, "deliver_as") || "email"

  # An unrecognized value finds no entry and requires nothing extra —
  # `typed/2` reports it against `:deliver_as` once the value is checked.
  defp deliver_as_entry(value) do
    Enum.find_value(@deliver_as, fn {known, entry} -> to_string(known) == value && entry end)
  end

  defp deliver_as_required(config) do
    case deliver_as_entry(current_deliver_as(config)) do
      nil -> []
      entry -> Enum.filter(@deliver_as_optional, fn {key, _} -> key in entry.required end)
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
    },
    create_task: %{
      required: [],
      # All optional: with none of them the reaction still works — it assigns to
      # the content's author, a week out, with a default note. `assignee_id` is
      # the fallback for content whose author cannot hold a task, which is a
      # thing a team discovers rather than anticipates.
      optional: [
        {"assignee_id", :string},
        {"due_in_days", :day_count},
        {"note", :template}
      ]
    }
  }

  @doc """
  What one action kind accepts: `%{required: [...], optional: [...]}`.

  Public so the admin UI can describe a reaction from the same source that
  enforces it, and so a test can assert every kind in
  `KilnCMS.Automation.Rule.action_kinds/0` has an entry.
  """
  # `optional(:required_when)`, not just `required:`/`optional:` — the four
  # intelligence-reaction shapes carry it (see `conditional_required/2`
  # below), and a spec that omitted it made dialyzer conclude that clause's
  # pattern, and `deliver_as_required/1` itself, could never match/run.
  @spec shape(atom()) ::
          %{optional(:required_when) => atom(), required: list(), optional: list()} | nil
  def shape(action), do: Map.get(@shapes, action)

  @doc "The shape table, keyed by action kind."
  @spec shapes() :: map()
  def shapes, do: @shapes

  @doc """
  The keys `action` requires for `config` as given — the unconditional
  `:required` list plus whatever a `:required_when` resolver adds for it.

  Public so the admin form marks a field required by the same rule `check/2`
  enforces: "to" is required on a `suggest_tags` rule delivering by email and
  not on one delivering as a comment, and only the config can say which.
  """
  @spec required_keys(atom(), map()) :: [String.t()]
  def required_keys(action, config) when is_map(config) do
    case shape(action) do
      nil -> []
      shape -> Enum.map(shape.required ++ conditional_required(shape, config), &elem(&1, 0))
    end
  end

  @doc "The `deliver_as` values, in the order the admin form offers them."
  @spec deliver_as_values() :: [String.t()]
  def deliver_as_values, do: @deliver_as_values

  @doc """
  Whether `key` is read by `action` given `config`.

  Every key is, except on the intelligence reactions, where a key belonging to
  a `deliver_as` landing place is only read when that landing place is the
  chosen one — `to` means nothing to a rule delivering as a comment. The admin
  form hides a key this returns `false` for.
  """
  @spec applicable?(atom(), String.t(), map()) :: boolean()
  def applicable?(action, key, config) when is_map(config) do
    case shape(action) do
      %{required_when: :deliver_as} ->
        owned? = Enum.any?(@deliver_as, fn {_value, entry} -> key in entry.uses end)
        current = deliver_as_entry(current_deliver_as(config))
        not owned? or (current != nil and key in current.uses)

      _shape ->
        true
    end
  end

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
  defp check(_shape, _config), do: error("must be a JSON object.", reason: "not_an_object")

  defp conditional_required(%{required_when: :deliver_as}, config),
    do: deliver_as_required(config)

  # A shape declaring a `:required_when` tag with no matching clause above is
  # a programmer error, not a config-authoring one — `required_when` only
  # ever comes from `@shapes`, never from a rule's own config — so it fails
  # loudly here rather than joining the plain no-tag case below and silently
  # enforcing nothing (#1252 review).
  defp conditional_required(%{required_when: other}, _config) do
    raise "ActionConfig: no conditional_required/2 clause for required_when: #{inspect(other)}"
  end

  defp conditional_required(_shape, _config), do: []

  defp missing(required, config) do
    case Enum.find(required, fn {key, _type} -> blank?(Map.get(config, key)) end) do
      nil ->
        :ok

      {key, _type} ->
        error("is missing `#{key}`, which this action needs to do anything.",
          config_key: key,
          reason: "missing"
        )
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
            "looks configured while doing nothing.",
          config_key: key,
          reason: "unknown"
        )
    end
  end

  defp typed(fields, config) do
    fields
    |> Enum.reject(fn {key, _type} -> is_nil(Map.get(config, key)) end)
    |> Enum.find_value(:ok, fn {key, type} ->
      value = Map.get(config, key)

      unless well_typed?(type, value) do
        detail = "#{expectation(type)}, got #{inspect(value)}."
        error("`#{key}` " <> detail, config_key: key, reason: "invalid", detail: detail)
      end
    end)
  end

  # A JSON boolean, never the string "true". Coercing it here would be the
  # wrong kind of generous: `allow_egress` is the switch that permits an
  # unattended reaction to send page bodies off-site, and "what counts as true"
  # is not a thing to guess at on an egress gate. `RuleWorker` already fails
  # closed on it; this makes the near-miss visible where it was typed.
  defp well_typed?(:boolean, value), do: is_boolean(value)

  # A review window, in days. Bounded here as well as in `RuleWorker` — the
  # worker clamps because it must not trust stored config (a rule may predate
  # this validation, or be seeded), and this refuses because a typo is worth
  # catching where it was typed rather than silently becoming seven.
  defp well_typed?(:day_count, value), do: is_integer(value) and value >= 1 and value <= 365
  defp well_typed?(:string, value), do: is_binary(value) and String.trim(value) != ""
  defp well_typed?(:template, value), do: well_typed?(:string, value)

  defp well_typed?(:email, value) do
    well_typed?(:string, value) and Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/u, value)
  end

  defp well_typed?(:provider, value) do
    well_typed?(:string, value) and Enum.any?(Account.providers(), &(to_string(&1) == value))
  end

  defp well_typed?(:deliver_as, value) do
    well_typed?(:string, value) and value in @deliver_as_values
  end

  # A uuid string, shallow-checked (format only) the same way `:email` is —
  # `assignee` naming a user who exists and is an editor/admin is
  # `KilnCMS.CMS.Validations.AssigneeIsEditor`'s job, at task-assignment time.
  defp well_typed?(:uuid, value) do
    well_typed?(:string, value) and match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp well_typed?(:integer, value), do: is_integer(value) and value > 0

  defp expectation(:boolean), do: "must be the JSON boolean true or false (not a string)"
  defp expectation(:day_count), do: "must be a whole number of days between 1 and 365"
  defp expectation(:email), do: "must be an email address"
  defp expectation(:provider), do: "must be one of #{list(Account.providers())}"
  defp expectation(:deliver_as), do: "must be one of #{list(@deliver_as_values)}"
  defp expectation(:uuid), do: "must be a uuid"
  defp expectation(:integer), do: "must be a positive whole number"
  defp expectation(_type), do: "must be a non-empty string"

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp list(values), do: values |> Enum.map_join(", ", &to_string/1)

  # `vars` carry the same facts as the message in structured form —
  # `config_key`, `reason` (`"missing"`/`"unknown"`/`"invalid"`/
  # `"not_an_object"`) and, for `"invalid"`, `detail` (the message minus its
  # key) — so the admin
  # form can put an error under its field and word it for that field without
  # parsing this English. None of them appears as a `%{}` placeholder in the
  # message, so Splode's interpolation leaves the message as written. Strings,
  # not atoms: AshPhoenix hands var values to the form stringified, and a
  # reason compared as an atom there would never match.
  defp error(message, vars) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :config,
       message: "Action config " <> message,
       vars: vars
     )}
  end
end
