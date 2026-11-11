defmodule KilnCMSWeb.FormFieldTypesApiTest do
  @moduledoc """
  The field types added in #2261, through the router: the headless schema
  (`GET /api/forms/:slug`), JSON submission (`POST /api/forms/:slug`) and the
  form-encoded `POST /forms/:slug` (checkboxes post `name[]`).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fta-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  @fields [
    %{name: "plan", label: "Plan", field_type: :radio, options: ["free", "pro"]},
    %{name: "tags", label: "Tags", field_type: :checkboxes, options: ["a", "b", "c"]},
    %{name: "phone", label: "Phone", field_type: :phone},
    %{name: "site", label: "Site", field_type: :url},
    %{name: "ref", label: "Ref", field_type: :hidden},
    %{name: "qty", label: "Qty", field_type: :number, min_value: 0.0, max_value: 10.0, step: 0.5},
    %{name: "stars", label: "Stars", field_type: :rating, max_value: 7.0},
    %{name: "stars5", label: "Stars default", field_type: :rating},
    %{name: "free", label: "Free number", field_type: :number},
    %{name: "name", label: "Name", field_type: :string}
  ]

  defp form!(required \\ []) do
    actor = admin()

    form =
      CMS.create_form!(%{name: "Types", slug: "fta-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    for attrs <- @fields do
      attrs = Map.merge(attrs, %{form_id: form.id, required: to_string(attrs.name) in required})
      CMS.create_form_field!(attrs, actor: actor)
    end

    form
  end

  defp json_post(conn, form, body) do
    conn
    |> unique_ip()
    |> put_req_header("content-type", "application/json")
    |> post("/api/forms/#{form.slug}", Jason.encode!(body))
  end

  defp stored(form), do: CMS.recent_form_submissions!(form.id, authorize?: false)

  describe "GET /api/forms/:slug" do
    test "min, max and step per type", %{conn: conn} do
      form = form!()
      body = conn |> get("/api/forms/#{form.slug}") |> json_response(200)
      by_name = Map.new(body["fields"], &{&1["name"], &1})

      assert %{
               "type" => "radio",
               "options" => ["free", "pro"],
               "min" => nil,
               "max" => nil,
               "step" => nil
             } =
               by_name["plan"]

      assert %{"type" => "checkboxes", "options" => ["a", "b", "c"], "min" => nil} =
               by_name["tags"]

      assert %{"type" => "phone", "max" => nil} = by_name["phone"]
      assert %{"type" => "url", "max" => nil} = by_name["site"]
      assert %{"type" => "hidden", "max" => nil} = by_name["ref"]
      assert %{"type" => "number", "min" => 0, "max" => 10, "step" => 0.5} = by_name["qty"]
      assert %{"type" => "number", "min" => nil, "max" => nil, "step" => nil} = by_name["free"]
      assert %{"type" => "rating", "min" => 1, "max" => 7, "step" => nil} = by_name["stars"]
      assert %{"type" => "rating", "max" => 5} = by_name["stars5"]
      assert %{"type" => "string", "min" => nil, "max" => nil, "step" => nil} = by_name["name"]
    end
  end

  describe "POST /api/forms/:slug" do
    test "valid values for every new type are stored with their shapes", %{conn: conn} do
      form = form!()

      assert %{"ok" => true} =
               conn
               |> json_post(form, %{
                 plan: "pro",
                 tags: ["c", "a", "a"],
                 phone: "+1 (555) 123-4567",
                 site: "https://example.com/x",
                 ref: "utm-1",
                 qty: "2.5",
                 stars: 6,
                 free: 4
               })
               |> json_response(200)

      assert [%{data: data}] = stored(form)

      assert %{
               "plan" => "pro",
               "tags" => ["a", "c"],
               "phone" => "+1 (555) 123-4567",
               "site" => "https://example.com/x",
               "ref" => "utm-1",
               "qty" => 2.5,
               "stars" => 6,
               "free" => 4
             } = data
    end

    test "invalid values are refused per field with a 422", %{conn: conn} do
      form = form!()

      body =
        conn
        |> json_post(form, %{
          plan: "enterprise",
          tags: ["a", "zzz"],
          phone: "abc",
          site: "javascript:alert(1)",
          qty: 99,
          stars: 8
        })
        |> json_response(422)

      assert body["ok"] == false
      for name <- ~w(plan tags phone site qty stars), do: assert(body["errors"][name], name)
      assert stored(form) == []
    end

    test "wrong shapes never 500", %{conn: conn} do
      form = form!()

      body =
        conn
        |> json_post(form, %{
          plan: ["pro"],
          tags: [1, ["a"]],
          phone: %{a: 1},
          qty: [1],
          stars: %{}
        })
        |> json_response(422)

      for name <- ~w(plan tags phone qty stars), do: assert(body["errors"][name], name)
    end

    test "required types refuse blanks, including an empty checkboxes list", %{conn: conn} do
      form = form!(~w(plan tags phone site qty stars))

      body = conn |> json_post(form, %{tags: [], plan: "", qty: nil}) |> json_response(422)

      for name <- ~w(plan tags phone site qty stars), do: assert(body["errors"][name], name)
    end

    test "optional new types may be omitted", %{conn: conn} do
      form = form!()

      assert %{"ok" => true} =
               conn |> json_post(form, %{name: "x", tags: []}) |> json_response(200)

      assert [%{data: data}] = stored(form)
      refute Map.has_key?(data, "tags")
    end
  end

  describe "POST /forms/:slug" do
    test "checkboxes post as name[]", %{conn: conn} do
      form = form!()

      html =
        conn
        |> unique_ip()
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/forms/#{form.slug}", "tags[]=b&tags[]=a&plan=free")
        |> html_response(200)

      assert html
      assert [%{data: %{"tags" => ["a", "b"], "plan" => "free"}}] = stored(form)
    end

    test "an invalid checkbox value re-renders with 422 and stores nothing", %{conn: conn} do
      form = form!()

      conn
      |> unique_ip()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/forms/#{form.slug}", "tags[]=a&tags[]=nope")
      |> html_response(422)

      assert stored(form) == []
    end
  end
end
