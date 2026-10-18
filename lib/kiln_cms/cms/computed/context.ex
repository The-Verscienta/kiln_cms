defmodule KilnCMS.CMS.Computed.Context do
  @moduledoc """
  Builds the value map a computed-field formula (`KilnCMS.CMS.Computed`) is
  evaluated against — the only data a formula can reach.

  Two entry points, one per evaluation site (#429):

    * `from_changeset/2` on write, reading the *effective* attribute values so
      a formula sees the merged result of the write rather than the record's
      pre-update state;
    * `from_document/3` on fire, reading a loaded document struct.

  Both produce the same shape, so a formula can't behave differently at the two
  sites:

      %{document: %{"title" => …, "body" => …, …}, fields: %{"price" => …}, today: ~D[…]}

  `body` is the block tree's plain text (`KilnCMS.CMS.BlockText`), which is
  what `word_count`/`reading_time` are for. A scalar the resource doesn't
  declare — `excerpt` on a type without one — resolves to nil, so the same
  formula is safe to reuse across content types.

  ## Pinning "today"

  `today()` answers the context's `:today`, never a clock (see
  `KilnCMS.CMS.Computed`, "`today()` and the daily refresh"). The date is
  pinned **once per evaluation pass** by the caller:

    * a write pins it on the changeset (`pin_today/1`, under
      `:computed_today` in the changeset context) the first time
      anything in the action needs it — the slug and alias derivations and
      `Changes.ApplyCustomFields` all read the same pinned date, and the fire
      the write enqueues carries it (`Changes.FireArtifacts`);
    * a fire takes it as `today:` (`KilnCMS.Firing.CustomFields.resolve/3`),
      from the job that enqueued it or else `today/1`;
    * a caller that already knows the day — the daily refresh, a test — puts
      it in the changeset context itself, and nothing downstream overrides it.

  "The day" is the site's: the date in `KilnCMS.Events.default_time_zone/0`,
  the zone `KilnCMS.Events.Index` already counts its days in. Kiln has no
  per-site timezone setting, so this is the deployment's.
  """
  alias KilnCMS.CMS.BlockText

  # Where a write's pinned date rides (see "Pinning today" above).
  @context_key :computed_today

  # The document scalars exposed to formulas, kept in step with
  # `KilnCMS.CMS.Computed.document_refs/0` (`body` is derived, not an
  # attribute, so it isn't in this list).
  @scalars [:title, :slug, :locale, :excerpt, :seo_title, :seo_description, :seo_keywords]

  @doc """
  The site's current date: `now` in `KilnCMS.Events.default_time_zone/0`.
  Takes `now` so a test can pin it.
  """
  @spec today(DateTime.t()) :: Date.t()
  def today(now \\ DateTime.utc_now()) do
    case DateTime.shift_zone(now, KilnCMS.Events.default_time_zone()) do
      {:ok, local} -> DateTime.to_date(local)
      # `default_time_zone/0` only answers zones the database knows, so this is
      # a zone database that has since lost one — UTC's day is the honest
      # fallback, not a crash on a content write.
      {:error, _reason} -> DateTime.to_date(now)
    end
  end

  @doc """
  Pin the date a write's formulas see on its changeset, unless something
  already did. Every change that evaluates a formula calls this (or
  `pinned_today/1`), so one write never mixes two days.
  """
  @spec pin_today(Ash.Changeset.t()) :: Ash.Changeset.t()
  def pin_today(%Ash.Changeset{context: %{@context_key => %Date{}}} = changeset), do: changeset

  def pin_today(changeset),
    do: Ash.Changeset.set_context(changeset, %{@context_key => today()})

  @doc """
  The date pinned on `changeset` (or in a plain context map, as an
  `after_transaction` hook sees it), or the site's current date when nothing
  pinned one.
  """
  @spec pinned_today(Ash.Changeset.t() | map()) :: Date.t()
  def pinned_today(%Ash.Changeset{context: context}), do: pinned_today(context)
  def pinned_today(%{@context_key => %Date{} = date}), do: date
  def pinned_today(_context), do: today()

  @doc """
  The changeset context that pins `today` for a write — for a caller that
  already knows the day (`KilnCMS.CMS.Computed.DailyRefresh`, a test):

      Ash.Changeset.for_update(record, :update, params,
        context: Context.pinned_context(~D[2026-10-17]))
  """
  @spec pinned_context(Date.t()) :: map()
  def pinned_context(%Date{} = today), do: %{@context_key => today}

  @doc """
  The date pinned on `changeset`, or nil — for a hook that should pass a
  pinned date along but must not invent one.
  """
  @spec pinned(Ash.Changeset.t()) :: Date.t() | nil
  def pinned(%Ash.Changeset{context: %{@context_key => %Date{} = date}}), do: date
  def pinned(_changeset), do: nil

  @doc """
  The context for a write, from the changeset's effective values, on the date
  pinned on the changeset (`pinned_today/1`).
  """
  @spec from_changeset(Ash.Changeset.t(), map()) :: map()
  def from_changeset(changeset, fields) do
    document =
      @scalars
      |> Enum.filter(&Ash.Resource.Info.attribute(changeset.resource, &1))
      |> Map.new(&{to_string(&1), scalar(Ash.Changeset.get_attribute(changeset, &1))})
      |> Map.put("body", BlockText.to_text(Ash.Changeset.get_attribute(changeset, :blocks)))

    %{document: document, fields: fields, today: pinned_today(changeset)}
  end

  @doc """
  The context for a loaded document, on the date `today` the caller pinned.
  `body` may be supplied when the caller has already extracted the block text
  (firing does), sparing a second walk of the tree.
  """
  @spec from_document(struct(), map(), Date.t(), String.t() | nil) :: map()
  def from_document(document, fields, %Date{} = today, body \\ nil) do
    scalars = Map.new(@scalars, &{to_string(&1), scalar(Map.get(document, &1))})

    %{
      document: Map.put(scalars, "body", body || BlockText.to_text(Map.get(document, :blocks))),
      fields: fields,
      today: today
    }
  end

  # Formulas work over JSON-native scalars. `seo_keywords` is a list, so join it
  # into something a formula can interpolate or slugify rather than handing the
  # evaluator a term it renders as blank.
  defp scalar(value) when is_list(value), do: Enum.map_join(value, ", ", &to_string/1)
  defp scalar(value), do: value
end
