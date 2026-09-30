defmodule KilnCMSWeb.AuthOverridesTest do
  @moduledoc """
  `KilnCMSWeb.AuthOverrides` is a Spark DSL with no schema: `set :whatever, "x"`
  compiles whether or not the component it names has ever heard of `:whatever`,
  and a key that does not land is simply never read. That is how the reset
  page's submit button came to say "Reset password with token" for as long as it
  did — `set :button_text, "Change password"` was written, compiled, reviewed,
  and ignored.

  The first block below closes that off for the whole file, against the list
  each component records at compile time in `__overrides__/0`. It is the real
  guard: an upstream rename drops a key out of that list, and a `set` that used
  to work starts failing here instead of quietly doing nothing.

  The second pins the one thing the file could not say on its own — see
  `KilnCMSWeb.AuthResetForm`. The third holds the other two forms Kiln renders
  from a copy — sign-in and register, copied to put an eye button beside their
  password boxes (#1806) — to the same standard.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshAuthentication.Phoenix.Components
  alias KilnCMSWeb.{AuthOverrides, AuthRegisterForm, AuthResetForm, AuthSignInForm}

  # What `Components.Reset.Form` labels its submit button when nobody passes it
  # one: `Phoenix.Naming.humanize/1` of the reset action's name. The whole point
  # of Kiln's form component is not shipping this.
  @upstream_label "Reset password with token"
  @kiln_label "Change password"

  describe "every setting in the file" do
    test "names a key the component it is written under declares" do
      case undeclared(AuthOverrides.overrides()) do
        [] ->
          :ok

        dead ->
          flunk("""
          These settings in `KilnCMSWeb.AuthOverrides` name keys their component
          does not declare, so they are read by nothing:

          #{Enum.map_join(dead, "\n", fn {component, key} -> "  override #{inspect(component)} do set #{inspect(key)}, ..." end)}

          Either the key was a typo, or upstream renamed or dropped it. Check the
          component's `use AshAuthentication.Phoenix.Overrides.Overridable` call
          for what it does declare, then fix or delete the setting — leaving it
          costs nothing at compile time and silently does nothing at runtime.
          """)
      end
    end

    # The check above is only worth having if it can fail. Both ways it is meant
    # to fire, fired deliberately:
    test "is checked against something that can actually say no" do
      # A key the component does declare.
      assert undeclared(%{{Components.Reset.Form, :root_class} => "x"}) == []

      # The original bug: a key it does not.
      assert undeclared(%{{Components.Reset.Form, :button_text} => "x"}) ==
               [{Components.Reset.Form, :button_text}]

      # A module that is not an overridable component at all — a plausible way
      # to mistype a component name into something that still resolves.
      assert undeclared(%{{AuthOverrides, :root_class} => "x"}) == [{AuthOverrides, :root_class}]
    end
  end

  describe "the reset form's submit button" do
    test "says what it does", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/password-reset/not-a-real-token")

      assert html =~ ">#{@kiln_label}</button>"
      refute html =~ @upstream_label
    end

    test "is the only thing Kiln's copy of the library's form changes" do
      # `KilnCMSWeb.AuthResetForm.render/1` is upstream's render with one prop
      # added, so it can go stale in a way delegation cannot. Rendering both
      # against the same assigns turns that into a failing test: anything
      # upstream changes in this form — a field, a class, the hidden token —
      # shows up here as a difference that is not the button's wording.
      # With the eye buttons (#1806) off: they are the other thing it changes,
      # and `KilnCMSWeb.PasswordRevealTest` covers them.
      assigns = Map.put(form_assigns(), :password_reveal, false)

      kiln = render_component(AuthResetForm, assigns)
      upstream = render_component(Components.Reset.Form, assigns)

      assert upstream =~ ">#{@upstream_label}</button>"
      assert kiln =~ ">#{@kiln_label}</button>"

      assert kiln
             |> String.replace(">#{@kiln_label}</button>", ">#{@upstream_label}</button>")
             |> squash() == squash(upstream)
    end
  end

  describe "Kiln's copies of the sign-in and register forms" do
    # Both renders are upstream's with the password boxes swapped for
    # `KilnCMSWeb.AuthPasswordInput`'s, which with the eye button off render
    # upstream's markup byte for byte. So with it off, the whole form must too:
    # anything upstream changes in either form shows up here as a difference.
    test "render exactly what upstream's do, eye buttons aside" do
      for {kiln, upstream, id} <- [
            {AuthSignInForm, Components.Password.SignInForm, "user-password-sign-in-form"},
            {AuthRegisterForm, Components.Password.RegisterForm, "user-password-register-form"}
          ] do
        assigns = Map.merge(password_form_assigns(id), %{password_reveal: false})

        assert squash(render_component(kiln, assigns)) ==
                 squash(render_component(upstream, assigns)),
               "#{inspect(kiln)} drifted from #{inspect(upstream)}"
      end
    end

    test "are what the pages render, with the eye buttons on", %{conn: conn} do
      assert AuthOverrides.override_for(
               [AuthOverrides],
               Components.Password,
               :sign_in_form_module
             ) == AuthSignInForm

      assert AuthOverrides.override_for(
               [AuthOverrides],
               Components.Password,
               :register_form_module
             ) == AuthRegisterForm

      {:ok, _view, html} = live(conn, ~p"/sign-in")
      assert html =~ "data-password-reveal"
    end
  end

  defp password_form_assigns(id) do
    %{
      id: id,
      strategy: AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password),
      label: false,
      auth_routes_prefix: "/auth",
      current_tenant: nil,
      gettext_fn: nil,
      overrides: [AuthOverrides]
    }
  end

  # Whitespace between tags is template layout, not markup: the copied field
  # branches on the eye button, so its indentation cannot match upstream's.
  defp squash(html), do: String.replace(html, ~r/>\s+</, "><")

  defp undeclared(overrides) do
    overrides
    |> Map.keys()
    |> Enum.filter(fn {component, key} ->
      Code.ensure_loaded!(component)

      not (function_exported?(component, :__overrides__, 0) and
             Map.has_key?(component.__overrides__(), key))
    end)
    |> Enum.sort()
  end

  defp form_assigns do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    %{
      id: "user-password-reset-form",
      strategy: strategy,
      token: "not-a-real-token",
      # What `KilnCMSWeb.AuthReset` passes, which is what upstream's
      # `Components.Reset` passes: the heading is the page's, not the form's.
      label: false,
      auth_routes_prefix: "/auth",
      current_tenant: nil,
      gettext_fn: nil,
      # What every auth route in `KilnCMSWeb.Router` passes, and deliberately
      # without the library's `Overrides.Default` behind it: Kiln's module is
      # the only one with an opinion on these pages.
      overrides: [AuthOverrides]
    }
  end
end
