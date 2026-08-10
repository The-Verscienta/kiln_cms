defmodule KilnCMSWeb.FormBuilderEmbedWarningTest do
  @moduledoc """
  The form builder's Embed-tab warning for the closed framing default (#562),
  and — since #648 — that the panel answers for *this form* rather than for the
  deployment.

  The suite-wide `:embed_origins` allowlist in `config/test.exs` means the
  warning branch never renders in `KilnCMSWeb.FormBuilderLiveTest` — which is
  exactly the production configuration it exists for. Cleared here instead, in
  an `async: false` module because `Application.delete_env/2` is global. That
  clearing is also what makes the #648 tests below say something: a form with
  its own allowlist has to report as embeddable while the deployment default it
  would otherwise inherit is closed.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  setup do
    previous = Application.get_env(:kiln_cms, :embed_origins)
    Application.delete_env(:kiln_cms, :embed_origins)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:kiln_cms, :embed_origins)
        value -> Application.put_env(:kiln_cms, :embed_origins, value)
      end
    end)

    :ok
  end

  # Same shape as KilnCMSWeb.FormBuilderLiveTest: seed, then sign in for real so
  # the session carries a usable token.
  defp admin do
    email = "fbw-#{System.unique_integer([:positive])}@example.com"

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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp form!(user, attrs \\ %{}) do
    CMS.create_form!(
      Map.merge(
        %{name: "Contact", slug: "fbw-#{System.unique_integer([:positive])}"},
        attrs
      ),
      actor: user
    )
  end

  defp embed_tab(conn, user, form) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/forms/#{form.id}")

    {lv, lv |> element(~s(nav button[phx-value-tab="embed"])) |> render_click()}
  end

  test "the embed tab warns that cross-site embedding is off", %{conn: conn} do
    user = admin()
    {_lv, html} = embed_tab(conn, user, form!(user))

    assert html =~ "Cross-site embedding is off"
    # No allowlist to show when embedding is closed.
    refute html =~ "Sites allowed to embed this form:"
    # The warning has to point at a control the admin can actually reach, and
    # the panel has to carry it. It used to name `EMBED_ORIGINS`, which an org
    # admin on a hosted instance cannot set.
    assert html =~ "List the sites that should be allowed to embed it below"
    assert html =~ ~s(name="form[embed_origins]")
    assert html =~ "Only these sites"
  end

  # The deployment allowlist is the union of every org's embedders, so naming it
  # in a tenant's panel lets org B's admin enumerate org A's partners. The
  # effective policy for *this* form is a different question, and the line above
  # answers that one.
  test "the panel never prints the deployment-wide allowlist", %{conn: conn} do
    user = admin()
    Application.put_env(:kiln_cms, :embed_origins, ["https://someone-elses-partner.test"])

    {_lv, html} = embed_tab(conn, user, form!(user, %{embed_origins: ["https://acme.test"]}))

    refute html =~ "someone-elses-partner.test"
  end

  # #648: the deployment default is closed, and this form is embeddable anyway,
  # because the answer the panel gives is the one its own request will serve.
  test "a form with its own allowlist reports as embeddable", %{conn: conn} do
    user = admin()
    form = form!(user, %{embed_origins: ["https://acme.test"]})

    {_lv, html} = embed_tab(conn, user, form)

    refute html =~ "Cross-site embedding is off"
    assert html =~ "Sites allowed to embed this form: https://acme.test"
  end

  test "saving the tab writes the form's own allowlist", %{conn: conn} do
    user = admin()
    form = form!(user)
    {lv, _html} = embed_tab(conn, user, form)

    html =
      lv
      |> form(~s(section form[phx-submit="save_form"]), %{
        "form" => %{
          "embed_mode" => "list",
          "embed_origins" => "https://acme.test, https://blog.acme.test"
        }
      })
      |> render_submit()

    assert html =~ "Sites allowed to embed this form: https://acme.test, https://blog.acme.test"

    assert CMS.get_form!(form.id, actor: user).embed_origins ==
             ["https://acme.test", "https://blog.acme.test"]
  end

  # A rejected entry has to come back as an error naming it. Dropping it and
  # saving the rest would leave an admin looking at a shorter allowlist than
  # they typed, with the omission indistinguishable from a deliberate one.
  test "a bad origin is refused rather than quietly dropped", %{conn: conn} do
    user = admin()
    form = form!(user)
    {lv, _html} = embed_tab(conn, user, form)

    html =
      lv
      |> form(~s(section form[phx-submit="save_form"]), %{
        "form" => %{"embed_mode" => "list", "embed_origins" => "https://acme.test, *"}
      })
      |> render_submit()

    # Naming the entry, not the field: `Splode` interpolates `vars` only inside
    # `Exception.message/1`, so reading `.message` off the struct rendered the
    # literal "%{value}" and told the admin a list was wrong without saying
    # which of its entries.
    assert html =~ "&quot;*&quot; is not an allowed CSP source"
    refute html =~ "%{value}"

    # And the seven good origins the admin typed are still in the box, so the
    # one typo does not cost them the whole list.
    assert html =~ ~s(value="https://acme.test, *")

    assert CMS.get_form!(form.id, actor: user).embed_origins == nil
  end

  # The radio and the box can contradict each other, and every way of silently
  # resolving that gets the admin's intent wrong: "only these sites" with an
  # empty box would store `[]`, which is *closed* — the other radio — and
  # "inherit" with a typed list would throw the list away. Both are refusals.
  test "a mode that contradicts the box is refused, not guessed at", %{conn: conn} do
    user = admin()
    form = form!(user, %{embed_origins: ["https://acme.test"]})
    {lv, _html} = embed_tab(conn, user, form)

    html =
      lv
      |> form(~s(section form[phx-submit="save_form"]), %{
        "form" => %{"embed_mode" => "list", "embed_origins" => "  "}
      })
      |> render_submit()

    assert html =~ "Add at least one site to embed on"
    assert CMS.get_form!(form.id, actor: user).embed_origins == ["https://acme.test"]

    html =
      lv
      |> form(~s(section form[phx-submit="save_form"]), %{
        "form" => %{"embed_mode" => "inherit", "embed_origins" => "https://new.test"}
      })
      |> render_submit()

    assert html =~ "Choose"
    assert CMS.get_form!(form.id, actor: user).embed_origins == ["https://acme.test"]
  end

  # One origin per line is what somebody pastes, and the Code Injection panel
  # already accepts it. Two admin surfaces feeding the same validation must not
  # disagree about what a separator is.
  test "origins may be separated by newlines as well as commas", %{conn: conn} do
    user = admin()
    form = form!(user)
    {lv, _html} = embed_tab(conn, user, form)

    lv
    |> form(~s(section form[phx-submit="save_form"]), %{
      "form" => %{
        "embed_mode" => "list",
        "embed_origins" => "https://acme.test\nhttps://blog.acme.test\n"
      }
    })
    |> render_submit()

    assert CMS.get_form!(form.id, actor: user).embed_origins ==
             ["https://acme.test", "https://blog.acme.test"]
  end

  # `nil` and `[]` render the same empty box, so the radio is the only thing
  # that can tell "inherit whatever the deployment allows" from "nobody".
  test "closing the form is distinguishable from inheriting", %{conn: conn} do
    user = admin()
    form = form!(user, %{embed_origins: ["https://acme.test"]})
    {lv, _html} = embed_tab(conn, user, form)

    lv
    |> form(~s(section form[phx-submit="save_form"]), %{
      "form" => %{"embed_mode" => "closed", "embed_origins" => ""}
    })
    |> render_submit()

    assert CMS.get_form!(form.id, actor: user).embed_origins == []
  end

  test "returning to inherit clears the form's own list", %{conn: conn} do
    user = admin()
    form = form!(user, %{embed_origins: ["https://acme.test"]})
    {lv, _html} = embed_tab(conn, user, form)

    lv
    |> form(~s(section form[phx-submit="save_form"]), %{
      "form" => %{"embed_mode" => "inherit", "embed_origins" => ""}
    })
    |> render_submit()

    assert CMS.get_form!(form.id, actor: user).embed_origins == nil
  end

  # Every other tab posts its own subset of fields. None of them may reset the
  # framing policy on its way past.
  test "saving another tab leaves the allowlist alone", %{conn: conn} do
    user = admin()
    form = form!(user, %{embed_origins: ["https://acme.test"]})

    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/forms/#{form.id}")
    lv |> element(~s(nav button[phx-value-tab="general"])) |> render_click()

    lv
    |> form(~s(section form[phx-submit="save_form"]), %{"form" => %{"name" => "Renamed"}})
    |> render_submit()

    assert %{name: "Renamed", embed_origins: ["https://acme.test"]} =
             CMS.get_form!(form.id, actor: user)
  end
end
