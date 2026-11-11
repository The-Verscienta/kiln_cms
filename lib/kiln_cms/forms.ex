defmodule KilnCMS.Forms do
  @moduledoc """
  The public-form submission pipeline (admin-defined forms — see
  `KilnCMS.CMS.Form`).

  `submit/3` takes the raw visitor params and runs the whole gauntlet:

    * **honeypot** — the rendered form carries a visually-hidden `website`
      input; bots that fill it get a *fake success* (the submission is
      silently discarded, giving spam software nothing to learn from);
    * **coercion + validation** per `FormField` (required, type coercion to
      JSON-native values, select membership, email shape), unknown keys
      dropped;
    * **storage** as a `FormSubmission` (privacy-first: no IP/user agent),
      scored against the `Kiln.Forms.SpamCheck` registry (#477);
    * **notification** — when the form has a `notify_email` and the
      submission wasn't scored `:spam`, an Oban job on the `:mail` queue
      delivers a summary;
    * **autoresponder** (#468) — when the form has one turned on and declares
      an `:email` field the submission filled in, a token-templated
      confirmation email goes back to the *submitter* — see
      `KilnCMS.Forms.Autoresponder`. Same `:spam` exclusion;
    * **webhook** — dispatches the `form.submitted` event with the form slug
      and coerced data, same `:spam` exclusion.

  Rate limiting happens at the controller (`KilnCMSWeb.RateLimit`, `:form`
  bucket) so the transient IP never reaches this module.

  ## Who the pipeline runs as

  A visitor has no actor, so everything the pipeline does past the policy-
  checked `get_active/2` runs as `system/0` (#1659): a `KilnCMS.SystemActor`
  admitted by name to `Form`'s `read`, `FormField`'s `for_form`,
  `FormSubmission`'s `create` and `SiteEmbedSettings`' `read` — see
  `docs/policy-matrix.md`, "The system actor". It cannot edit or delete a
  form, or read a submission back.
  """

  alias KilnCMS.CMS
  alias KilnCMS.Forms.Autoresponder

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @honeypot_field "website"
  @rendered_at_field "_kiln_rendered_at"
  # Carries the experiment variant the page was rendered with (#499).
  @variant_field "_kiln_variant"
  @rendered_at_salt "form_rendered_at"
  # Bounds how long a rendered-but-unsubmitted form is honored, so the token
  # can't be replayed indefinitely — not a security boundary (nothing sensitive
  # rides in it, just a millisecond timestamp), only a sanity window.
  @rendered_at_max_age :timer.hours(24)

  @doc """
  The actor the form pipeline runs as: the submission write and the field
  read behind it, the notification and autoresponder workers' re-reads, the
  autoresponder-template validation's field read and the embed route's
  per-site default (`KilnCMS.Forms.EmbedPolicy`). See "Who the pipeline runs
  as" above.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:forms)
      actor -> actor
    end
  end

  @doc false
  # Test seam (#1659): run `fun` with `system/0` answering `actor` in this
  # process. It exists so a test can take the grant away and prove that the
  # reads the pipeline decides on fail CLOSED rather than filtering to
  # "nothing", which is how a refused read answers. Process-local, and nothing
  # on a request path calls it; code that could call it could equally pass
  # any actor it liked.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun) do
    previous = Process.get(@actor_override, :unset)
    Process.put(@actor_override, actor)

    try do
      fun.()
    after
      if previous == :unset,
        do: Process.delete(@actor_override),
        else: Process.put(@actor_override, previous)
    end
  end

  @doc "The honeypot input name rendered into public forms."
  @spec honeypot_field() :: String.t()
  def honeypot_field, do: @honeypot_field

  @doc "The fill-time token's hidden input name, rendered into public forms."
  @spec rendered_at_field() :: String.t()
  def rendered_at_field, do: @rendered_at_field

  @doc """
  A signed token carrying "now", minted when a public form renders — the
  fill-time spam signal (#477, `Kiln.Forms.SpamCheck.Checks.FillTime`).
  Signed (not encrypted): the value itself, a millisecond timestamp, is not
  sensitive; signing only stops a submitter from just supplying their own
  "I rendered ages ago" timestamp.
  """
  @spec rendered_at_token() :: String.t()
  def rendered_at_token,
    do:
      Phoenix.Token.sign(KilnCMSWeb.Endpoint, @rendered_at_salt, System.system_time(:millisecond))

  @doc """
  How long ago (in milliseconds) a form carrying `token` was rendered, or
  `nil` when the token is missing, forged, older than
  #{div(@rendered_at_max_age, 60_000)} minutes, or the computed delta is
  negative — a headless/JSON caller with no rendered page to time simply
  sends none, and gets `nil` here rather than an error.

  The negative case is deliberate, not a stray guard: on a multi-node
  deployment, the node that minted the token and the node verifying it can
  disagree by however much their clocks have drifted. Flooring a negative
  delta to `0` would read as "submitted instantly" on every request that
  happens to land on a node running slightly behind — indistinguishable from
  a genuine bot and, unlike a bot, load-bearing on nothing the visitor did.
  `nil` (no signal) is the honest answer to "we can't tell."
  """
  @spec fill_time_ms(term()) :: non_neg_integer() | nil
  def fill_time_ms(token) when is_binary(token) do
    case Phoenix.Token.verify(KilnCMSWeb.Endpoint, @rendered_at_salt, token,
           max_age: div(@rendered_at_max_age, 1000)
         ) do
      {:ok, rendered_at_ms} ->
        case System.system_time(:millisecond) - rendered_at_ms do
          delta when delta >= 0 -> delta
          _negative -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  def fill_time_ms(_token), do: nil

  @doc """
  One active form by slug within `org` (the request's site — epic #336), fields
  included, or nil. `org` defaults to the sole org so any tenant-less caller keeps
  working under the single-org rollout.
  """
  @spec get_active(String.t(), Ash.ToTenant.t() | nil) :: struct() | nil
  def get_active(slug, org \\ KilnCMS.Accounts.default_org_id()) when is_binary(slug) do
    case CMS.get_active_form_by_slug(slug, load: [:fields], authorize?: true, tenant: org) do
      {:ok, form} -> form
      _ -> nil
    end
  end

  @doc """
  Validate and record one submission. Returns:

    * `{:ok, submission}` — stored (and notifications queued);
    * `{:ok, :discarded}` — the honeypot tripped: report success upstream,
      store nothing;
    * `{:error, errors}` — a `%{"field" => "message"}` map for re-rendering.

  `opts`: `:locale` (recorded on the submission).

  The fill-time spam signal (#477) is read straight from `params` here
  (`rendered_at_field/0`), not from `opts` — unlike `:locale`, which the
  controller derives from request context, this rides on the form itself as
  an ordinary field, so a JSON caller with no rendered page to time simply
  omits it.
  """
  @spec submit(struct(), map(), keyword()) ::
          {:ok, struct() | :discarded} | {:error, %{optional(String.t()) => String.t()}}
  def submit(form, params, opts \\ []) when is_map(params) do
    cond do
      not form.active ->
        {:error, %{"form" => "is no longer accepting submissions"}}

      honeypot_tripped?(params) ->
        {:ok, :discarded}

      true ->
        form_fields = fields(form)

        case coerce(form_fields, params) do
          {:ok, data} -> {:ok, record(form, form_fields, data, params, opts)}
          {:error, errors} -> {:error, errors}
        end
    end
  end

  @doc """
  The hidden field a rendered page uses to carry its assigned experiment variant
  back on submission (#499). Named like the other machinery fields so an editor's
  own field can never collide with it.
  """
  @spec variant_field() :: String.t()
  def variant_field, do: @variant_field

  @doc """
  Whether a public submission's params trip the honeypot (`honeypot_field/0`).

  The one rule every public surface that renders the honeypot shares — form
  submissions here and newsletter sign-up (`KilnCMSWeb.NewsletterController`,
  #1657). Only an absent field or the empty string a browser submits for an
  untouched input counts as a human. Anything else trips it: any non-empty
  string — whitespace-only included, since a human never sees the field to type
  a space into it — and any non-string value (a list or map no text input
  produces).
  """
  @spec honeypot_tripped?(map()) :: boolean()
  def honeypot_tripped?(params) when is_map(params) do
    case Map.get(params, @honeypot_field) do
      nil -> false
      "" -> false
      _filled -> true
    end
  end

  defp fields(%{fields: fields}) when is_list(fields), do: fields

  # `authorize_with: :error` (#1659): the field list is what the submission is
  # validated against. A refused read filtering to `[]` would accept any
  # submission — every required field skipped, every value dropped — and store
  # it empty. A refusal raises instead.
  defp fields(form) do
    CMS.form_fields_for!(form.id, actor: system(), authorize_with: :error, tenant: form.org_id)
  end

  defp record(form, form_fields, data, params, opts) do
    # Every write here is scoped to the form's own site (epic #336): the
    # submission lands in the form's org, and the webhook dispatch is scoped to it.
    submission =
      CMS.create_form_submission!(
        %{
          form_id: form.id,
          data: data,
          locale: Keyword.get(opts, :locale),
          fill_time_ms: fill_time_ms(Map.get(params, @rendered_at_field))
        },
        actor: system(),
        tenant: form.org_id
      )

    # #477: a submission the scorer flagged never reaches the autoresponder or
    # the webhook — mailing a spammer back (sender-reputation risk) or firing
    # an integration on payload that was never worth acting on.
    unless submission.status == :spam do
      notify(form, data)
      autorespond(form, form_fields, data)
      count_experiment_conversion(params, form)
      KilnCMS.Webhooks.dispatch("form.submitted", %{form: form.slug, data: data}, form.org_id)
    end

    submission
  end

  # A/B experiments (#499). The rendered page injected the variant it served as a
  # hidden field, so the conversion is attributed to the arm the visitor actually
  # saw — which is why a form submission is the one goal that needs no visitor
  # state at all, and the goal v1 leads with.
  #
  # Inside the `unless` deliberately: a submission the spam scorer flagged is not
  # a conversion, and counting it would let anyone move an experiment's numbers
  # by posting at it. A tripped honeypot never reaches here for the same reason.
  defp count_experiment_conversion(params, form) do
    params
    |> Map.get(@variant_field)
    |> KilnCMS.Experiments.Delivery.record_conversion(form.org_id, form_id: form.id)
  end

  defp notify(%{notify_email: email} = form, data) when is_binary(email) and email != "" do
    # `org_id` scopes the worker's form re-fetch to the form's site (epic #336).
    %{form_id: form.id, org_id: form.org_id, data: data}
    |> KilnCMS.Forms.NotificationWorker.new()
    |> Oban.insert!()
  end

  defp notify(_form, _data), do: :ok

  # #468: the submitter's confirmation email — `Autoresponder.eligible?/3` is
  # the single place that decides whether there's anyone to send it to.
  defp autorespond(form, form_fields, data) do
    case Autoresponder.eligible?(form, data, form_fields) do
      {true, to} ->
        %{form_id: form.id, org_id: form.org_id, to: to, data: data}
        |> KilnCMS.Forms.AutoresponderWorker.new()
        |> Oban.insert!()

      false ->
        :ok
    end
  end

  # --- coercion ---------------------------------------------------------------

  defp coerce(fields, params) do
    {data, errors} =
      Enum.reduce(fields, {%{}, %{}}, fn field, {data, errors} ->
        case resolve(field, Map.get(params, field.name)) do
          :skip -> {data, errors}
          {:ok, value} -> {Map.put(data, field.name, value), errors}
          {:error, message} -> {data, Map.put(errors, field.name, message)}
        end
      end)

    if errors == %{}, do: {:ok, data}, else: {:error, errors}
  end

  defp resolve(field, raw) do
    cond do
      blank?(field, raw) and field.required -> {:error, "is required"}
      blank?(field, raw) -> :skip
      true -> cast(field, raw)
    end
  end

  # A checkboxes field posts a list (`name[]=a&name[]=b`), and an unticked
  # group arrives as `[]` or as a list of empty sentinels — blank, so a
  # required group says "is required" and an optional one stores nothing. A
  # list for any other type is not blank: `cast/2` refuses it (#751).
  defp blank?(%{field_type: :checkboxes}, raw) when is_list(raw), do: Enum.all?(raw, &blank?/1)
  defp blank?(_field, raw), do: blank?(raw)

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  @doc """
  The attributes of a `KilnCMS.CMS.FormField` that a copy carries (field
  duplicate, form duplicate): everything but identity (`form_id`, `name`,
  `position`), which the caller sets. One list, so a new attribute can't be
  copied by one site and dropped by the other.
  """
  @spec copyable_field_attrs(map()) :: map()
  def copyable_field_attrs(field) do
    Map.take(field, [
      :label,
      :field_type,
      :required,
      :options,
      :help_text,
      :placeholder,
      :default_value,
      :width,
      :min_value,
      :max_value,
      :step
    ])
  end

  @doc """
  A submitted value as display text, for every surface that shows a
  submission's `data` (notification mail, autoresponder tokens, the Entries
  tab, the CSV export): a list (checkboxes) is joined with `", "`, a float is
  written without an exponent, `nil` is `""`.
  """
  @spec display_value(term()) :: String.t()
  def display_value(nil), do: ""
  def display_value(value) when is_binary(value), do: value
  def display_value(value) when is_list(value), do: Enum.map_join(value, ", ", &display_value/1)

  def display_value(value) when is_float(value),
    do: value |> Decimal.from_float() |> Decimal.to_string(:normal)

  def display_value(value) when is_number(value) or is_boolean(value) or is_atom(value),
    do: to_string(value)

  def display_value(value), do: inspect(value)

  # A checkboxes value is the one list a field accepts: `name[]=a&name[]=b`, a
  # JSON array, or a lone string (one box). Every element must be a string
  # naming an option; blanks (the empty sentinel an unticked group posts) and
  # repeats are dropped, and the stored list follows the options' order.
  defp cast(%{field_type: :checkboxes, options: options}, value)
       when is_list(value) or is_binary(value) do
    picked = value |> List.wrap() |> Enum.reject(&blank?/1)

    cond do
      not Enum.all?(picked, &is_binary/1) ->
        {:error, "is not valid"}

      length(picked) > length(options) ->
        {:error, "is not valid"}

      true ->
        picked = picked |> Enum.map(&String.trim/1) |> MapSet.new()

        if MapSet.subset?(picked, MapSet.new(options)),
          do: {:ok, Enum.filter(options, &MapSet.member?(picked, &1))},
          else: {:error, "is not one of the allowed options"}
    end
  end

  # Any other shape (a map, a number, a boolean) is not a checkbox group.
  defp cast(%{field_type: :checkboxes}, _value), do: {:error, "is not valid"}

  # A submitted value arrives from a query string or a JSON body, so the client
  # chooses its shape: `message[a]=hi` is a map. Nothing below has a clause for
  # one and `to_string/1` raises on it, which would 500 an anonymous,
  # CSRF-exempt endpoint. Rejected as invalid input, which is what it is.
  defp cast(_field, value) when is_list(value) or is_map(value),
    do: {:error, "is not valid"}

  defp cast(%{field_type: type}, value) when type in [:string, :text] do
    {:ok, value |> to_string() |> String.trim()}
  end

  # The HTML5 `<input type="email">` pattern (WHATWG living standard) —
  # deliberately tighter than "not whitespace or @": the autoresponder (#468)
  # hands this value straight to Swoosh as a literal SMTP recipient, and
  # `,`/`;` are valid in `[^\s@]+` but not in a real address, which would let
  # a submitted value smuggle in an extra recipient.
  @email_pattern ~r/\A[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+\z/

  defp cast(%{field_type: :email}, value) do
    str = value |> to_string() |> String.trim()

    if Regex.match?(@email_pattern, str),
      do: {:ok, str},
      else: {:error, "must be an email address"}
  end

  defp cast(%{field_type: :integer}, value) do
    case value do
      v when is_integer(v) ->
        {:ok, v}

      v ->
        case Integer.parse(to_string(v)) do
          {n, ""} -> {:ok, n}
          _ -> {:error, "must be a whole number"}
        end
    end
  end

  defp cast(%{field_type: :boolean}, value) do
    case value do
      v when is_boolean(v) -> {:ok, v}
      v when v in ["true", "1", "on"] -> {:ok, true}
      v when v in ["false", "0", "off"] -> {:ok, false}
      _ -> {:error, "must be a boolean"}
    end
  end

  defp cast(%{field_type: :date}, value) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, "must be a date (YYYY-MM-DD)"}
    end
  end

  defp cast(%{field_type: type, options: options}, value) when type in [:select, :radio] do
    str = value |> to_string() |> String.trim()
    if str in options, do: {:ok, str}, else: {:error, "is not one of the allowed options"}
  end

  # Digits and the separators people type; 6..15 digits (E.164's ceiling) in
  # at most 32 characters. Stored as typed (trimmed), not normalised. The
  # length is bounded before the pattern runs.
  @phone_pattern ~r/\A[0-9+() .\-]+\z/

  defp cast(%{field_type: :phone}, value) do
    str = value |> to_string() |> String.trim()

    if byte_size(str) <= 32 and Regex.match?(@phone_pattern, str) and
         digit_count(str) in 6..15,
       do: {:ok, str},
       else: {:error, "must be a phone number"}
  end

  # http(s) only, with a host and no credentials: the value is echoed in the
  # Entries tab and notification mail, so `javascript:`/`data:` and
  # `user:pass@` forms never get stored.
  defp cast(%{field_type: :url}, value) do
    str = value |> to_string() |> String.trim()

    if byte_size(str) <= KilnCMS.Limits.url() and url?(str),
      do: {:ok, str},
      else: {:error, "must be a URL starting with http:// or https://"}
  end

  # Free text by definition: the client sets it (a script fills utm params),
  # so it is bounded and nothing more.
  defp cast(%{field_type: :hidden}, value) do
    str = value |> to_string() |> String.trim()

    if String.length(str) <= KilnCMS.Limits.line(),
      do: {:ok, str},
      else: {:error, "is too long"}
  end

  defp cast(%{field_type: :number} = field, value) do
    with {:ok, decimal} <- number_decimal(value),
         :ok <- number_in_range(field, decimal) do
      {:ok, number_value(decimal)}
    end
  end

  defp cast(%{field_type: :rating} = field, value) do
    max = rating_max(field)

    case rating_integer(value) do
      n when is_integer(n) and n >= 1 and n <= max -> {:ok, n}
      _ -> {:error, "must be a rating from 1 to #{max}"}
    end
  end

  defp digit_count(str), do: str |> :binary.bin_to_list() |> Enum.count(&(&1 in ?0..?9))

  defp url?(str) do
    with false <- String.match?(str, ~r/[\s\x00-\x1f\x7f]/),
         %URI{scheme: scheme, host: host, userinfo: nil} <- URI.parse(str),
         true <- is_binary(scheme) and String.downcase(scheme) in ["http", "https"] do
      is_binary(host) and host != ""
    else
      _ -> false
    end
  end

  # A whole-or-decimal literal, built as a Decimal from the text (never via a
  # float): no exponent, `nan`/`inf`, `.5`, `5.` or `1_000`. JSON numbers
  # arrive as integers/floats, which are finite by construction.
  @number_pattern ~r/\A[+-]?[0-9]+(\.[0-9]+)?\z/

  defp number_decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp number_decimal(value) when is_float(value), do: {:ok, Decimal.from_float(value)}

  defp number_decimal(value) when is_binary(value) do
    str = String.trim(value)

    with true <- byte_size(str) <= 64 and Regex.match?(@number_pattern, str),
         {decimal, ""} <- Decimal.parse(str) do
      {:ok, decimal}
    else
      _ -> {:error, "must be a number"}
    end
  end

  defp number_decimal(_value), do: {:error, "must be a number"}

  defp number_in_range(%{min_value: min, max_value: max, step: step}, decimal) do
    with :ok <- check_min(min, decimal),
         :ok <- check_max(max, decimal) do
      check_step(step, min, decimal)
    end
  end

  defp check_min(min, decimal) when is_number(min) do
    if Decimal.lt?(decimal, bound(min)),
      do: {:error, "must be at least #{bound_text(min)}"},
      else: :ok
  end

  defp check_min(_min, _decimal), do: :ok

  defp check_max(max, decimal) when is_number(max) do
    if Decimal.gt?(decimal, bound(max)),
      do: {:error, "must be at most #{bound_text(max)}"},
      else: :ok
  end

  defp check_max(_max, _decimal), do: :ok

  defp check_step(step, min, decimal) when is_number(step) and step > 0 do
    if on_step?(decimal, bound(min || 0), bound(step)),
      do: :ok,
      else: {:error, "must be a multiple of #{bound_text(step)}"}
  end

  defp check_step(_step, _min, _decimal), do: :ok

  defp bound(number) when is_integer(number), do: Decimal.new(number)
  defp bound(number) when is_float(number), do: Decimal.from_float(number)

  defp bound_text(number),
    do: number |> bound() |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp on_step?(decimal, base, step) do
    decimal |> Decimal.sub(base) |> Decimal.rem(step) |> Decimal.eq?(0)
  end

  # Whole values are stored as integers (`1.0` -> 1, `-0` -> 0), the rest as
  # floats.
  defp number_value(decimal) do
    if Decimal.integer?(decimal),
      do: Decimal.to_integer(decimal),
      else: Decimal.to_float(decimal)
  end

  defp rating_max(%{max_value: max}) when is_number(max), do: trunc(max)
  defp rating_max(_field), do: 5

  defp rating_integer(value) when is_integer(value), do: value

  defp rating_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp rating_integer(_value), do: nil
end
