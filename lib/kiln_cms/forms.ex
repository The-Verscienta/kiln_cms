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
  """

  alias KilnCMS.CMS
  alias KilnCMS.Forms.Autoresponder

  @honeypot_field "website"
  @rendered_at_field "_kiln_rendered_at"
  # Carries the experiment variant the page was rendered with (#499).
  @variant_field "_kiln_variant"
  @rendered_at_salt "form_rendered_at"
  # Bounds how long a rendered-but-unsubmitted form is honored, so the token
  # can't be replayed indefinitely — not a security boundary (nothing sensitive
  # rides in it, just a millisecond timestamp), only a sanity window.
  @rendered_at_max_age :timer.hours(24)

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

  defp honeypot_tripped?(params) do
    case Map.get(params, @honeypot_field) do
      value when is_binary(value) -> String.trim(value) != ""
      nil -> false
      _non_string -> true
    end
  end

  defp fields(%{fields: fields}) when is_list(fields), do: fields
  defp fields(form), do: CMS.form_fields_for!(form.id, authorize?: false, tenant: form.org_id)

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
        authorize?: false,
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
      blank?(raw) and field.required -> {:error, "is required"}
      blank?(raw) -> :skip
      true -> cast(field, raw)
    end
  end

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

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

  defp cast(%{field_type: :select, options: options}, value) do
    str = value |> to_string() |> String.trim()
    if str in options, do: {:ok, str}, else: {:error, "is not one of the allowed options"}
  end
end
