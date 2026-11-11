defmodule KilnCMS.NewerReleaseRows do
  @moduledoc """
  Rows a newer release wrote, for testing how this one reads them (#2509).

  A security event, a notification or a custom field definition (#2605)
  whose type this release does not know cannot be made through the resource
  (input stays strict), so it is inserted as raw SQL, the way the newer
  release's code would have stored it. The stored name is a string no code in
  this VM names as an atom.
  """

  @unknown "zz_from_a_newer_release_2509"

  @doc "The stored name of the type this release does not know."
  @spec unknown() :: String.t()
  def unknown, do: @unknown

  @doc """
  Insert a `security_events` row with `type` (default `unknown/0`). Takes
  `:org_id`, `:actor_id`, `:actor_label`, `:target_type`, `:target_id`,
  `:ip`, `:user_agent`, `:metadata`, `:inserted_at`. Returns its id.
  """
  @spec security_event!(map()) :: Ecto.UUID.t()
  def security_event!(attrs \\ %{}) do
    id = Ecto.UUID.generate()

    KilnCMS.Repo.query!(
      """
      INSERT INTO security_events
        (id, org_id, type, actor_id, actor_label, target_type, target_id, ip,
         user_agent, metadata, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      """,
      [
        dump(id),
        dump(Map.get(attrs, :org_id, KilnCMS.Accounts.default_org_id())),
        Map.get(attrs, :type, @unknown),
        dump(attrs[:actor_id]),
        attrs[:actor_label],
        attrs[:target_type],
        dump(attrs[:target_id]),
        attrs[:ip],
        attrs[:user_agent],
        Map.get(attrs, :metadata, %{}),
        Map.get(attrs, :inserted_at, DateTime.utc_now())
      ]
    )

    id
  end

  @doc """
  Insert an unread `notifications` row for `user_id` with `event` (default
  `unknown/0`). Takes `:org_id`, `:event`, `:actor_id`, `:actor_name`,
  `:title`, `:read_at`. Returns its id.
  """
  @spec notification!(Ecto.UUID.t(), map()) :: Ecto.UUID.t()
  def notification!(user_id, attrs \\ %{}) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    KilnCMS.Repo.query!(
      """
      INSERT INTO notifications
        (id, org_id, user_id, event, content_type, content_id, title, actor_id,
         actor_name, read_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $11)
      """,
      [
        dump(id),
        dump(Map.get(attrs, :org_id, KilnCMS.Accounts.default_org_id())),
        dump(user_id),
        Map.get(attrs, :event, @unknown),
        "page",
        dump(Ecto.UUID.generate()),
        Map.get(attrs, :title, "From a newer release"),
        dump(attrs[:actor_id]),
        attrs[:actor_name],
        attrs[:read_at],
        now
      ]
    )

    id
  end

  @doc """
  The stored name of a custom field type this release does not know (#2605):
  no atom of it exists in this VM.
  """
  @spec unknown_field_type() :: String.t()
  def unknown_field_type, do: "zz_field_type_from_a_newer_release_2605"

  @doc """
  Insert a `field_definitions` row whose `field_type` (default
  `unknown_field_type/0`) this release may not know (#2605). Takes `:org_id`,
  `:content_type` (a type name, default `"page"`; pass `nil` with
  `:type_definition_id`), `:type_definition_id`, `:link_of_id`,
  `:group_of_id`, `:name`, `:label`, `:field_type`, `:private`,
  `:validation`, `:position`. Returns its id.
  """
  @spec field_definition!(map()) :: Ecto.UUID.t()
  def field_definition!(attrs \\ %{}) do
    id = Ecto.UUID.generate()

    KilnCMS.Repo.query!(
      """
      INSERT INTO field_definitions
        (id, org_id, content_type, type_definition_id, link_of_id, group_of_id,
         name, label, field_type, private, validation, position)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
      """,
      [
        dump(id),
        dump(Map.get(attrs, :org_id, KilnCMS.Accounts.default_org_id())),
        Map.get(attrs, :content_type, "page"),
        dump(attrs[:type_definition_id]),
        dump(attrs[:link_of_id]),
        dump(attrs[:group_of_id]),
        Map.get(attrs, :name, "newer_#{System.unique_integer([:positive])}"),
        Map.get(attrs, :label, "From a newer release"),
        Map.get(attrs, :field_type, unknown_field_type()),
        Map.get(attrs, :private, false),
        Map.get(attrs, :validation, %{}),
        Map.get(attrs, :position, 0)
      ]
    )

    id
  end

  @doc """
  A row as stored, read past every Ash type: a map of column name to raw
  value (uuids as 16-byte binaries).
  """
  @spec stored_row(String.t(), Ecto.UUID.t()) :: %{String.t() => term()}
  def stored_row(table, id) when table in ~w(security_events notifications) do
    %{columns: columns, rows: [row]} =
      KilnCMS.Repo.query!("SELECT * FROM #{table} WHERE id = $1", [dump(id)])

    columns |> Enum.zip(row) |> Map.new()
  end

  defp dump(nil), do: nil
  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
