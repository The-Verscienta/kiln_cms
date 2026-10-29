defmodule KilnCMSWeb.ContentEditorSharedRelationshipsTest do
  @moduledoc """
  The editor's half of #1859: on a translation of a type that shares its tags
  and related content, both pickers are read-only, labelled as shared with a
  link to the source, and re-send the stored links unchanged — so a save is
  never refused for them (`KilnCMS.I18n.Validations.SharedFieldsReadOnly`).
  The events that would change them re-check the lock server-side.

  `async: false`: the page type opts its relationships in through the
  operator config, which is VM-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations
  alias KilnCMS.I18n.SharedFieldsWorker
  alias KilnCMSWeb.ContentEditor.ReferencePicker

  @password "password123456"

  setup do
    previous = Application.get_env(:kiln_cms, :i18n)

    Application.put_env(
      :kiln_cms,
      :i18n,
      Keyword.put(previous, :field_localization, page: [shared: [:tags, :related]])
    )

    on_exit(fn -> Application.put_env(:kiln_cms, :i18n, previous) end)

    actor = admin()
    kept = CMS.create_tag!(%{name: "Kept", slug: slug()}, actor: actor)
    other = CMS.create_tag!(%{name: "Other", slug: slug()}, actor: actor)
    target = CMS.create_page!(%{title: "Target", slug: slug(), locale: "en"}, actor: actor)
    extra = CMS.create_page!(%{title: "Extra", slug: slug(), locale: "en"}, actor: actor)

    en =
      CMS.create_page!(
        %{
          title: "Product",
          slug: slug(),
          locale: "en",
          tag_ids: [kept.id],
          related_page_ids: [target.id]
        },
        actor: actor
      )

    en = CMS.publish_page!(en, %{}, actor: actor)
    fr = Translations.create_translation!(:page, en, "fr", actor: actor)
    fr = CMS.publish_page!(fr, %{}, actor: actor)

    :ok =
      SharedFieldsWorker.perform(%Oban.Job{
        args: %{"org_id" => fr.org_id, "type" => "page", "id" => fr.id}
      })

    %{actor: actor, kept: kept, other: other, target: target, extra: extra, en: en, fr: fr}
  end

  defp admin do
    email = "srel-ed-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp slug, do: "srel-ed-#{System.unique_integer([:positive])}"

  defp open_editor(conn, user, page) do
    {:ok, lv, html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(~p"/editor/content/page/#{page.id}")

    {lv, html}
  end

  defp tag_checkbox(id), do: ~s(#tag-picker input[type=checkbox][value="#{id}"])
  defp tag_resent(id), do: ~s(#tag-picker input[type=hidden][value="#{id}"])
  defp related_held(id), do: ~s(#related-content input[type=hidden][value="#{id}"])

  test "on a translation the tags and related content are shown read-only", ctx do
    {lv, _html} = open_editor(build_conn(), ctx.actor, ctx.fr)

    # The tag checkboxes are disabled; a hidden input re-sends the stored set.
    assert has_element?(lv, tag_checkbox(ctx.kept.id) <> "[disabled][checked]")
    assert has_element?(lv, tag_checkbox(ctx.other.id) <> "[disabled]")
    assert has_element?(lv, tag_resent(ctx.kept.id))
    refute has_element?(lv, tag_resent(ctx.other.id))

    # The related picker keeps its list and offers no search.
    assert has_element?(lv, related_held(ctx.target.id))
    refute has_element?(lv, "#custom-field-_related-search")

    # Both are labelled as owned by the source, with a link to it.
    for section <- [
          "#tag-picker + [data-localization=shared]",
          "#related-content [data-localization=shared]"
        ] do
      assert has_element?(lv, section, "Shared: edited in the EN version.")
      assert has_element?(lv, section <> ~s( a[href="/editor/content/page/#{ctx.en.id}"]))
    end
  end

  test "the events that would change them are refused on a translation", ctx do
    {lv, _html} = open_editor(build_conn(), ctx.actor, ctx.fr)

    # The picker offers no inline create here, and a replayed one neither
    # makes the tag nor ticks it.
    refute has_element?(lv, "#tag-picker-create")
    render_click(lv, "create_tag", %{"name" => "Brand new"})
    refute render(lv) =~ "Brand new"
    assert {:ok, []} = CMS.list_tags(actor: ctx.actor, query: [filter: [name: "Brand new"]])

    send(lv.pid, {ReferencePicker, {:add, "_related", ctx.extra.id}})
    refute has_element?(lv, related_held(ctx.extra.id))

    send(lv.pid, {ReferencePicker, {:remove, "_related", ctx.target.id}})
    assert has_element?(lv, related_held(ctx.target.id))
  end

  test "on the source the same pickers are editable", ctx do
    {lv, _html} = open_editor(build_conn(), ctx.actor, ctx.en)

    assert has_element?(lv, tag_checkbox(ctx.other.id))
    refute has_element?(lv, tag_checkbox(ctx.other.id) <> "[disabled]")
    assert has_element?(lv, "#custom-field-_related-search")
    assert has_element?(lv, "[data-localization=shared]", "Shared with 1 other locale")

    send(lv.pid, {ReferencePicker, {:add, "_related", ctx.extra.id}})
    assert has_element?(lv, related_held(ctx.extra.id))
  end
end
