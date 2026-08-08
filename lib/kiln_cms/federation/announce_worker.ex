defmodule KilnCMS.Federation.AnnounceWorker do
  @moduledoc """
  Builds one activity and fans it out to a site's followers (#491).

  Runs after the publish transaction has committed, so it reads the **live**
  record rather than the event payload. That matters twice over: the payload is
  a snapshot that may already be stale, and it does not carry `audience` at all
  — the single most important field for deciding whether something may be
  federated.

  ## Every gate is checked here, not at enqueue time

  Federation on for the deployment and for the site; the type syndicates; the
  record is published, `:public`, and in the default locale. A job that fails
  any of them returns `:ok` and does nothing — these are ordinary outcomes, not
  errors to retry.
  """
  use Oban.Worker,
    queue: :federation,
    max_attempts: 3,
    unique: [
      period: 60,
      keys: [:org_id, :document_id, :verb],
      states: [:scheduled, :available, :executing, :retryable, :suspended]
    ]

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Federation
  alias KilnCMS.Federation.Activity
  alias KilnCMS.Federation.Actor
  alias KilnCMS.Federation.DeliveryWorker
  alias KilnCMS.Federation.Follower

  require Ash.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"org_id" => org_id, "type" => type, "verb" => verb, "document_id" => document_id} = args

    with true <- Federation.enabled?(),
         {:ok, settings} <- site_settings(org_id),
         {:ok, descriptor} <- syndicated_type(type, org_id),
         {:ok, document} <- federatable_document(descriptor, document_id, org_id, verb) do
      fan_out(settings, document, verb, org_id)
    else
      _skip -> :ok
    end
  end

  # ── gates ───────────────────────────────────────────────────────────────────

  defp site_settings(org_id) do
    case Federation.list_site_federation(authorize?: false, tenant: org_id) do
      {:ok, [%{enabled: true, origin: origin} = settings]} when is_binary(origin) ->
        {:ok, settings}

      _other ->
        :skip
    end
  end

  # An operator who chose not to syndicate a type in the site's feed did not
  # choose to broadcast it to the fediverse either.
  defp syndicated_type(type, org_id) do
    case Enum.find(KilnCMS.Feeds.syndicated_types(org_id), &(to_string(&1.type) == type)) do
      nil -> :skip
      descriptor -> {:ok, descriptor}
    end
  end

  # A `Delete` is the one verb that must work for a record that is no longer
  # readable as published — that is the whole point of it.
  defp federatable_document(descriptor, document_id, org_id, "Delete") do
    case load(descriptor, document_id, org_id) do
      {:ok, record} -> {:ok, record}
      _other -> {:ok, %{id: document_id, title: nil, slug: nil, locale: nil}}
    end
  end

  defp federatable_document(descriptor, document_id, org_id, _verb) do
    with {:ok, record} <- load(descriptor, document_id, org_id),
         true <- record.state == :published,
         true <- Map.get(record, :audience, :public) == :public,
         # A passphrase-locked document (#496) is not announced. An Announce is a
         # push to strangers' timelines with the title and a link; a lock says
         # this document is for whoever holds the passphrase, and federating it
         # is the loudest possible way to ignore that.
         true <- is_nil(Map.get(record, :access_password_hash)),
         true <- record.locale == KilnCMS.I18n.default_locale() do
      {:ok, record}
    else
      _other -> :skip
    end
  end

  defp load(%{resource: resource}, document_id, org_id) when not is_nil(resource) do
    case Ash.get(resource, document_id, authorize?: false, tenant: org_id) do
      {:ok, record} -> {:ok, record}
      _other -> :skip
    end
  end

  defp load(_descriptor, _document_id, _org_id), do: :skip

  # ── fan-out ─────────────────────────────────────────────────────────────────

  defp fan_out(settings, document, verb, org_id) do
    identity = Actor.identity(settings)
    activity = build(verb, document, identity, settings, org_id)

    followers =
      Follower
      |> Ash.Query.filter(consecutive_failures < ^Federation.drop_follower_after())
      |> Ash.read!(authorize?: false, tenant: org_id)

    Enum.each(followers, fn follower ->
      {:ok, delivery} =
        Federation.create_federation_delivery(
          %{
            follower_id: follower.id,
            inbox_uri: Follower.delivery_inbox(follower),
            activity_type: verb |> String.downcase() |> String.to_existing_atom(),
            activity: activity,
            document_id: document.id
          },
          authorize?: false,
          tenant: org_id
        )

      %{"org_id" => org_id, "delivery_id" => delivery.id}
      |> DeliveryWorker.new()
      |> Oban.insert()
    end)

    :ok
  end

  defp build("Delete", document, identity, _settings, _org_id),
    do: Activity.delete(%{id: document.id}, identity)

  defp build(verb, record, identity, settings, org_id) do
    document = to_document(record, identity, settings, org_id)

    case verb do
      "Create" -> Activity.create(document, identity)
      "Update" -> Activity.update(document, identity)
    end
  end

  defp to_document(record, identity, _settings, org_id) do
    descriptor = ContentTypes.get(to_string(document_type(record)), org_id)

    %{
      id: record.id,
      type: to_string(document_type(record)),
      title: record.title,
      url: public_url(record, descriptor, identity),
      summary: summary(record),
      published_at: record.published_at || record.inserted_at,
      updated_at: record.updated_at,
      markdown: markdown(record, org_id)
    }
  end

  defp document_type(%module{}) do
    if function_exported?(module, :__kiln_content_type__, 0),
      do: module.__kiln_content_type__(),
      else: :entry
  end

  # Built from the actor's **pinned** origin, not from `Tenant.base_url/1`: a
  # federated object's `url` must keep resolving under the same host its `id`
  # was minted under, or a follower's click lands somewhere the actor never
  # claimed.
  defp public_url(record, descriptor, identity) do
    prefix = if descriptor, do: ContentTypes.public_prefix(descriptor), else: ""
    locale = locale_prefix(record.locale)

    identity.origin <> locale <> "#{prefix}/#{record.slug}"
  end

  defp locale_prefix(locale) do
    if locale in [nil, ""] or locale == KilnCMS.I18n.default_locale(), do: "", else: "/#{locale}"
  end

  defp summary(record) do
    [Map.get(record, :excerpt), Map.get(record, :seo_description)]
    |> Enum.find(nil, &(is_binary(&1) and &1 != ""))
  end

  # The `:llm` artifact is already clean chunked Markdown of exactly the
  # published content. Absent (the window before firing completes) is fine —
  # `source` is optional, and an activity without it still carries the title,
  # summary and link that a timeline actually renders.
  defp markdown(record, org_id) do
    case KilnCMS.Firing.Engine.read(org_id, document_type(record), record.id, :llm) do
      {:ok, %{"markdown" => markdown}} when is_binary(markdown) -> markdown
      _other -> nil
    end
  end
end
