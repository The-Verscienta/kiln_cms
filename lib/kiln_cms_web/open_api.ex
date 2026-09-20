defmodule KilnCMSWeb.OpenApi do
  @moduledoc """
  Customizes the OpenAPI 3 spec that AshJsonApi generates for the headless
  JSON:API surface (`KilnCMS.CMS`).

  AshJsonApi derives the bulk of the spec — every content path, schema and the
  `bearerAuth` security scheme — from the resources' `json_api` config. This
  module is wired in as the `:modify_open_api` callback on
  `KilnCMSWeb.AshJsonApiRouter` (issue #37) and layers in the bits AshJsonApi
  can't infer from the resources alone:

    * a human-readable `info` block (description, contact, license) that covers
      **authentication** and the wider delivery surface (GraphQL, webhooks,
      preview tokens) which live outside the JSON:API router;
    * concrete `servers` for dev/prod so "Try it out" in Swagger UI targets the
      running host;
    * relaxing the global security requirement so the spec reflects reality —
      published content is world-readable, a bearer token only *widens* access
      to drafts.

  The result is published at `/api/json/open_api` wherever `:api_docs` is on (#567) and is
  the spec backing the Swagger UI at `/api/json/swaggerui`.
  """

  @version Mix.Project.config()[:version]

  @description """
  The [JSON:API](https://jsonapi.org/)-compliant headless surface of
  **KilnCMS**: reads, search and — since #330 — writes, for the core content
  types **Page** and **Post**, admin-defined types through **Entry**
  (`/api/json/entries`, described by `/api/json/type-definitions`), the
  **MediaItem** library, and the taxonomy (**Tag**, **TagGroup**, **Category**)
  plus **Redirect**.

  ## Authentication

  Requests are **anonymous by default** and resolved through each resource's read
  policy, so an unauthenticated caller only ever sees **published** content — no
  credentials are required for the public delivery use case.

  A credential widens that, as far as its account's role allows. Both kinds go
  in the same header:

  ```
  Authorization: Bearer <credential>
  ```

    * **API key** (`kiln_…`, the `apiKeyAuth` scheme) — minted at
      `/editor/api-keys`, acting as the account that minted it and bounded by
      the key's `access` scope. A `read` key reads what its account may read;
      a `read_write` key may also **write**: create and update drafts, submit
      for review, and — on an admin account — publish, unpublish, return to
      draft and soft-delete. The key for server-to-server use.
    * **User JWT** (the `bearerAuth` scheme) — an AshAuthentication token from
      **`POST /api/auth/sign_in`** (documented below), with that user's role.

  Either credential also authenticates the GraphQL endpoint (`POST /gql`) and
  its WebSocket. See `docs/api.md` and, for the write routes, `docs/json-api.md`
  → "Writing".

  ## Content negotiation

  Every request and response uses the JSON:API media type:

  ```
  Accept: application/vnd.api+json
  Content-Type: application/vnd.api+json
  ```

  ## Filtering, sorting & pagination

  Collection routes accept `filter[<field>]=`, `sort=<field>` (prefix `-` for
  descending) and the `page[...]` family (`page[limit]` defaults to 25, capped
  at 100; `page[offset]`, `page[after]`/`page[before]` keyset cursors,
  `page[count]=true`). Full reference: `docs/json-api.md`.

  ## Beyond JSON:API

  The JSON:API router is one of several headless surfaces. Those with an
  operation below are marked; the rest are in `docs/api.md`.

    * **GraphQL** delivery, search and authoring at `POST /gql`
      (`docs/headless-graphql-api.md`); its schema as SDL at
      `GET /api/graphql/schema.graphql` (operation below).
    * **Fired artifacts** — the rendered block tree — at
      `GET /api/content/:type/:slug` (operation below).
    * **Media upload** at `POST /api/media` (multipart), `POST /api/media/import-url`
      and the presigned direct-upload pair under `/api/media/uploads`
      (`docs/api.md` → "Uploading media"). Metadata edits are the JSON:API
      `PATCH /api/json/media-items/{id}` below.
    * **Search, resolve, menus, locales, forms, related, ask, provenance** under
      `/api/*`.
    * **MCP** for LLM authoring clients at `/mcp` (`docs/mcp.md`).
    * **Outbound webhooks** (HMAC-signed) on publish/unpublish/update.
    * **Signed preview URLs** for unpublished content at `GET /preview/:token`
      (operation below).

  ## This document

  A production build serves it only to a caller holding an API key, unless the
  operator turns the public documentation on (`API_DOCS_ENABLED`). The copy
  committed at `docs/api/openapi.json` describes the stock build.
  """

  @doc """
  AshJsonApi `:modify_open_api` callback. Receives the generated
  `%OpenApiSpex.OpenApi{}`, the (optional) `conn` and the router opts, and
  returns the enriched spec.
  """
  def modify(spec, conn, _opts) do
    %{
      spec
      | paths:
          spec.paths
          |> Map.merge(auth_paths())
          |> Map.merge(delivery_paths())
          |> Map.merge(media_paths()),
        info: %{
          spec.info
          | title: "KilnCMS Headless API",
            version: @version,
            description: @description,
            contact: %OpenApiSpex.Contact{
              name: "KilnCMS",
              url: "https://github.com/The-Verscienta/kiln_cms"
            },
            license: %OpenApiSpex.License{
              name: "MIT",
              url: "https://github.com/The-Verscienta/kiln_cms/blob/main/LICENSE"
            }
        },
        servers: servers(spec, conn),
        components: add_api_key_scheme(spec.components),
        # Published content is world-readable; a credential only widens access.
        # An empty requirement alongside the two schemes marks auth as optional
        # rather than required on every operation.
        security: [%{}, %{"apiKeyAuth" => []}, %{"bearerAuth" => []}]
    }
  end

  # AshJsonApi declares one scheme, the user JWT. API keys ride the same
  # `Authorization: Bearer` header (`KilnCMSWeb.Plugs.ApiKeyAuth` tells them
  # apart by prefix), and they are the credential the write routes are built
  # for, so they get a scheme of their own for clients to generate against.
  defp add_api_key_scheme(components) do
    schemes =
      components
      |> Map.get(:securitySchemes, %{})
      |> Map.put("apiKeyAuth", %OpenApiSpex.SecurityScheme{
        type: "http",
        scheme: "bearer",
        bearerFormat: "kiln_ API key",
        description:
          "An API key minted at `/editor/api-keys`, sent as " <>
            "`Authorization: Bearer kiln_…`. Acts as its owning account, bounded " <>
            "by the key's `access` scope (`read` or `read_write`)."
      })

    Map.put(components, :securitySchemes, schemes)
  end

  # The headless sign-in endpoint lives outside the AshJsonApi domain (it's a
  # plain Phoenix controller), so AshJsonApi can't derive it — describe it here.
  defp auth_paths do
    %{
      "/api/auth/sign_in" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags: ["Authentication"],
          operationId: "signIn",
          summary: "Exchange credentials for a bearer token",
          description:
            "Sign in with an editor/admin email + password and receive an " <>
              "AshAuthentication JWT for `Authorization: Bearer <token>`. " <>
              "Public; no authentication required.\n\n" <>
              "If the account has two-factor authentication enabled this " <>
              "answers **200** with `two_factor_required` and a short-lived " <>
              "`pending_token` instead of **201** with a JWT — redeem it at " <>
              "`POST /api/auth/sign_in/verify`. Branch on the status code, not " <>
              "on the presence of `token`.",
          # No bearer requirement — this is how you *get* the bearer token.
          security: [],
          requestBody: %OpenApiSpex.RequestBody{
            required: true,
            content: %{
              "application/json" => %OpenApiSpex.MediaType{
                schema: %OpenApiSpex.Schema{
                  type: :object,
                  required: [:email, :password],
                  properties: %{
                    email: %OpenApiSpex.Schema{type: :string, format: :email},
                    password: %OpenApiSpex.Schema{type: :string, format: :password}
                  }
                }
              }
            }
          },
          responses: %{
            200 => %OpenApiSpex.Response{
              description:
                "Two-factor required — no token issued. Redeem `pending_token` " <>
                  "at `POST /api/auth/sign_in/verify`.",
              content: %{
                "application/json" => %OpenApiSpex.MediaType{
                  schema: pending_schema()
                }
              }
            },
            201 => %OpenApiSpex.Response{
              description: "Signed in — bearer token issued",
              content: %{
                "application/json" => %OpenApiSpex.MediaType{schema: token_schema()}
              }
            },
            401 => %OpenApiSpex.Response{description: "Invalid email or password"},
            422 => %OpenApiSpex.Response{description: "Missing email or password"},
            429 => %OpenApiSpex.Response{
              description:
                "Rate limited — per-IP `auth` bucket, or the per-account " <>
                  "sign-in budget. See `Retry-After`."
            }
          }
        }
      },
      "/api/auth/sign_in/verify" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags: ["Authentication"],
          operationId: "signInVerify",
          summary: "Complete a two-factor sign-in",
          description:
            "Exchange the `pending_token` from `POST /api/auth/sign_in` plus a " <>
              "TOTP code (or a one-time recovery code) for the bearer token. " <>
              "The pending token is valid for 300 seconds; codes are budgeted " <>
              "per account across this endpoint and the browser prompt, so a " <>
              "429 here is not reset by signing in again.",
          security: [],
          requestBody: %OpenApiSpex.RequestBody{
            required: true,
            content: %{
              "application/json" => %OpenApiSpex.MediaType{
                schema: %OpenApiSpex.Schema{
                  type: :object,
                  required: [:pending_token, :code],
                  properties: %{
                    pending_token: %OpenApiSpex.Schema{
                      type: :string,
                      description: "The `pending_token` from the sign-in response"
                    },
                    code: %OpenApiSpex.Schema{
                      type: :string,
                      description: "6-digit TOTP code, or a recovery code"
                    }
                  }
                }
              }
            }
          },
          responses: %{
            201 => %OpenApiSpex.Response{
              description: "Signed in — bearer token issued",
              content: %{
                "application/json" => %OpenApiSpex.MediaType{schema: token_schema()}
              }
            },
            401 => %OpenApiSpex.Response{
              description:
                "Invalid code (`invalid_code`), or the pending token has " <>
                  "expired or is no longer usable (`pending_expired`)"
            },
            422 => %OpenApiSpex.Response{description: "Missing pending_token or code"},
            429 => %OpenApiSpex.Response{
              description: "Per-account second-factor budget spent — see `Retry-After`"
            }
          }
        }
      }
    }
  end

  defp token_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        token: %OpenApiSpex.Schema{type: :string, description: "JWT bearer token"},
        user: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            id: %OpenApiSpex.Schema{type: :string, format: :uuid},
            email: %OpenApiSpex.Schema{type: :string},
            role: %OpenApiSpex.Schema{type: :string, enum: ["admin", "editor", "viewer"]}
          }
        }
      }
    }
  end

  defp pending_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        two_factor_required: %OpenApiSpex.Schema{type: :boolean, enum: [true]},
        pending_token: %OpenApiSpex.Schema{
          type: :string,
          description:
            "Opaque and encrypted. Treat it as a credential: it names the " <>
              "account and carries the sign-in this exchange will complete. " <>
              "Redeemed at most once, and only for `expires_in` seconds."
        },
        expires_in: %OpenApiSpex.Schema{
          type: :integer,
          description: "Seconds the pending token remains valid"
        }
      }
    }
  end

  # Headless surfaces that live outside the AshJsonApi domain — the fired-artifact
  # endpoint and signed preview links — so Swagger documents them as real
  # operations instead of only prose (#191).
  defp delivery_paths do
    %{
      "/api/content/{type}/{slug}" => %OpenApiSpex.PathItem{
        get: %OpenApiSpex.Operation{
          tags: ["Delivery"],
          operationId: "getArtifact",
          summary: "Fetch a published document's fired artifact",
          description:
            "Returns the immutable, pre-compiled output for a published page/post " <>
              "(Kiln v2 — D9). `surface` selects `json` (default), `json_ld`, " <>
              "`web`, or `llm` — `llm` responds with raw `text/markdown` (#357), " <>
              "every other surface with JSON. Public; only published content is " <>
              "reachable. A 503 with `Retry-After` means the artifact is still " <>
              "compiling.",
          security: [],
          parameters: [
            path_param(:type, "Content type (e.g. `page`, `post`)"),
            path_param(:slug, "Content slug"),
            query_param(:surface, "Artifact surface", enum: ["json", "json_ld", "web", "llm"]),
            query_param(:locale, "Locale code (defaults to the site default)")
          ],
          responses: %{
            200 => %OpenApiSpex.Response{
              description: "The fired artifact for the requested surface"
            },
            404 => %OpenApiSpex.Response{description: "Unknown type/slug or unpublished content"},
            503 => %OpenApiSpex.Response{
              description: "Artifact is compiling — retry after the header delay"
            }
          }
        }
      },
      "/api/graphql/schema.graphql" => %OpenApiSpex.PathItem{
        get: %OpenApiSpex.Operation{
          tags: ["Delivery"],
          operationId: "getGraphqlSchema",
          summary: "Fetch the GraphQL schema as SDL",
          description:
            "The running site's GraphQL schema, for codegen where introspection " <>
              "is off. Public wherever GraphQL introspection is enabled; " <>
              "otherwise it needs an API key (`apiKeyAuth`), and anyone else " <>
              "gets a 404.",
          security: [%{}, %{"apiKeyAuth" => []}],
          responses: %{
            200 => %OpenApiSpex.Response{
              description: "The schema in GraphQL SDL",
              content: %{
                "application/graphql" => %OpenApiSpex.MediaType{
                  schema: %OpenApiSpex.Schema{type: :string}
                }
              }
            },
            404 => %OpenApiSpex.Response{
              description: "Introspection is off and the request carried no API key"
            }
          }
        }
      },
      "/preview/{token}" => %OpenApiSpex.PathItem{
        get: %OpenApiSpex.Operation{
          tags: ["Delivery"],
          operationId: "getPreview",
          summary: "Fetch an unpublished document via a signed preview token",
          description:
            "Returns a single referenced draft of any content type (curated public fields; " <>
              "a live document's unpublished working copy) " <>
              "for a short-lived signed token. No account needed; the token is the " <>
              "credential.",
          security: [],
          parameters: [path_param(:token, "Signed preview token")],
          responses: %{
            200 => %OpenApiSpex.Response{description: "The draft document"},
            404 => %OpenApiSpex.Response{description: "Invalid or expired preview link"}
          }
        }
      },
      "/api/content/{type}/{id}/preview-token" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags: ["Delivery"],
          operationId: "createPreviewToken",
          summary: "Mint a short-lived preview link for one draft",
          description:
            "Returns a signed, read-only token for this one document (redeem it at " <>
              "`GET /preview/{token}`), its shareable `url` on the owning site's host, " <>
              "and when it expires (15 minutes). Requires a caller who sees this " <>
              "document's drafts as an editor; a `:read` API key is enough.",
          security: [%{"bearerAuth" => []}],
          parameters: [
            path_param(:type, "Content type name, e.g. `post`"),
            path_param(:id, "The document's id")
          ],
          responses: %{
            201 => %OpenApiSpex.Response{
              description: "`{token, url, type, id, expires_at, expires_in}`"
            },
            401 => %OpenApiSpex.Response{description: "No (valid) credential"},
            403 => %OpenApiSpex.Response{
              description: "Readable, but not as an editor (e.g. a viewer on a published page)"
            },
            404 => %OpenApiSpex.Response{description: "Unknown type or document"}
          }
        }
      }
    }
  end

  # The media upload API (`KilnCMSWeb.MediaUploadController`) — plain Phoenix
  # routes like the two above, so AshJsonApi cannot derive them. Every
  # operation needs a `:read_write` key (or JWT) on an editor/admin account;
  # the refusals share `KilnCMSWeb.ApiError`'s envelope and its `code`s are the
  # ones docs/api.md's "Upload errors" table lists.
  defp media_paths do
    %{
      "/api/media" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags: ["Media"],
          operationId: "uploadMedia",
          summary: "Upload a file to the media library",
          description:
            "Multipart upload of one `file`, with optional metadata. The file is " <>
              "byte-sniffed (its name and `Content-Type` are ignored), size-capped " <>
              "per kind (images 10 MB, documents 25 MB, captions 2 MB, audio " <>
              "100 MB, video 500 MB), metadata-stripped, stored and recorded as " <>
              "the credential's user — the media library's own pipeline. The " <>
              "caller is authorized **before** the body is read. Rate limited by " <>
              "the `media_upload` bucket on top of `api`.",
          security: [%{"bearerAuth" => []}],
          requestBody: %OpenApiSpex.RequestBody{
            required: true,
            content: %{
              "multipart/form-data" => %OpenApiSpex.MediaType{
                schema: %OpenApiSpex.Schema{
                  type: :object,
                  required: [:file],
                  properties:
                    Map.merge(media_metadata_properties(), %{
                      file: %OpenApiSpex.Schema{type: :string, format: :binary},
                      "tag_ids[]": %OpenApiSpex.Schema{
                        type: :array,
                        items: %OpenApiSpex.Schema{type: :string, format: :uuid},
                        description: "Tag ids, one repeated field per id"
                      }
                    })
                    |> Map.delete(:tag_ids)
                }
              }
            }
          },
          responses:
            media_created_responses(%{
              413 => error_response("Over the cap for the file's kind (`too_large`)"),
              415 => error_response("Not a kind the library accepts (`unsupported_media_type`)"),
              422 =>
                error_response(
                  "`missing_file`, `invalid_parameter`, `create_failed`, `encrypted`, " <>
                    "`strip_unavailable` or `strip_failed`"
                ),
              502 => error_response("The object store refused the write (`storage_failed`)"),
              503 =>
                error_response(
                  "Out of temp disk to strip a video (`insufficient_storage`) — see `Retry-After`"
                )
            })
        }
      },
      "/api/media/import-url" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags: ["Media"],
          operationId: "importMediaFromUrl",
          summary: "Import a file from a public URL",
          description:
            "The server fetches `url` through its SSRF-guarded fetcher — public " <>
              "http(s) addresses only, resolved once and connected to by address, " <>
              "up to three redirects each re-validated, at most 25 MB — and " <>
              "ingests it exactly like an upload.",
          security: [%{"bearerAuth" => []}],
          requestBody:
            json_body(
              [:url],
              Map.merge(media_metadata_properties(), %{
                url: %OpenApiSpex.Schema{type: :string, format: :uri},
                filename: %OpenApiSpex.Schema{
                  type: :string,
                  description: "Name to record instead of the one the URL's path implies"
                }
              })
            ),
          responses:
            media_created_responses(%{
              413 => error_response("Over the kind's cap, or the 25 MB import cap (`too_large`)"),
              415 => error_response("Not a kind the library accepts (`unsupported_media_type`)"),
              422 =>
                error_response(
                  "`unsafe_url` (not a public address), `fetch_failed` (no 2xx), " <>
                    "`invalid_parameter`, `create_failed`, or a strip refusal"
                )
            })
        }
      },
      "/api/media/uploads" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags: ["Media"],
          operationId: "beginDirectUpload",
          summary: "Start a direct upload: get a presigned PUT URL",
          description:
            "For files too large to send through the app. Returns a URL to " <>
              "`PUT` exactly `byte_size` bytes to (in the deployment's private " <>
              "bucket, valid 15 minutes, the length signed in — send `headers` as " <>
              "given) and a `token` for `POST /api/media/uploads/complete`, valid " <>
              "one hour for the same user on the same site. Needs S3 storage " <>
              "with a private bucket; otherwise 501.",
          security: [%{"bearerAuth" => []}],
          requestBody:
            json_body([:filename, :byte_size], %{
              filename: %OpenApiSpex.Schema{type: :string},
              byte_size: %OpenApiSpex.Schema{
                type: :integer,
                minimum: 1,
                description: "The file's exact size in bytes"
              }
            }),
          responses:
            auth_error_responses(%{
              201 => %OpenApiSpex.Response{
                description: "Upload issued",
                content: %{
                  "application/json" => %OpenApiSpex.MediaType{schema: direct_upload_schema()}
                }
              },
              413 => error_response("`byte_size` is over the largest upload cap (`too_large`)"),
              422 =>
                error_response("Missing or invalid `filename`/`byte_size` (`invalid_parameter`)"),
              501 =>
                error_response(
                  "This deployment can't presign — no S3 private bucket (`direct_uploads_unavailable`)"
                )
            })
        }
      },
      "/api/media/uploads/complete" => %OpenApiSpex.PathItem{
        post: %OpenApiSpex.Operation{
          tags: ["Media"],
          operationId: "completeDirectUpload",
          summary: "Finish a direct upload",
          description:
            "Runs the staged object through the same pipeline as " <>
              "`POST /api/media`, then deletes the staged copy whatever the " <>
              "outcome. A token completes once. Metadata is set here.",
          security: [%{"bearerAuth" => []}],
          requestBody:
            json_body(
              [:token],
              Map.put(media_metadata_properties(), :token, %OpenApiSpex.Schema{
                type: :string,
                description: "The `token` from `POST /api/media/uploads`"
              })
            ),
          responses:
            media_created_responses(%{
              413 => error_response("Over the cap for the file's kind (`too_large`)"),
              415 => error_response("Not a kind the library accepts (`unsupported_media_type`)"),
              422 =>
                error_response(
                  "`invalid_upload_token`, `not_uploaded` (nothing staged, or already " <>
                    "completed), `size_mismatch`, `invalid_parameter`, `create_failed`, " <>
                    "or a strip refusal"
                ),
              501 => error_response("No S3 private bucket (`direct_uploads_unavailable`)")
            })
        }
      }
    }
  end

  # The metadata every upload route accepts (JSON spelling; multipart sends the
  # same names as form fields, `tag_ids[]` repeated).
  defp media_metadata_properties do
    %{
      alt: %OpenApiSpex.Schema{type: :string},
      caption: %OpenApiSpex.Schema{type: :string},
      decorative: %OpenApiSpex.Schema{
        type: :boolean,
        description: "A decorative image correctly has no alt text"
      },
      focal_x: %OpenApiSpex.Schema{type: :number, minimum: 0, maximum: 1, default: 0.5},
      focal_y: %OpenApiSpex.Schema{type: :number, minimum: 0, maximum: 1, default: 0.5},
      tag_ids: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :string, format: :uuid},
        description: "Tags on this site to attach"
      }
    }
  end

  defp json_body(required, properties) do
    %OpenApiSpex.RequestBody{
      required: true,
      content: %{
        "application/json" => %OpenApiSpex.MediaType{
          schema: %OpenApiSpex.Schema{type: :object, required: required, properties: properties}
        }
      }
    }
  end

  defp media_created_responses(errors) do
    auth_error_responses(
      Map.put(errors, 201, %OpenApiSpex.Response{
        description:
          "Created. `Location` names the item's JSON:API route; the body is the " <>
            "same resource object `GET /api/json/media-items/{id}` serves, plus " <>
            "`kind` and `meta.processing`.",
        headers: %{
          "location" => %OpenApiSpex.Header{
            description: "`/api/json/media-items/{id}`",
            schema: %OpenApiSpex.Schema{type: :string}
          }
        },
        content: %{"application/json" => %OpenApiSpex.MediaType{schema: media_item_schema()}}
      })
    )
  end

  # 401/403/429 answer every media route the same way.
  defp auth_error_responses(responses) do
    Map.merge(
      %{
        401 => error_response("No credential (`unauthorized`)"),
        403 =>
          error_response("A read-only key, or an account that can't create media (`forbidden`)"),
        429 => error_response("`media_upload` or `api` bucket spent — see `Retry-After`")
      },
      responses
    )
  end

  defp error_response(description) do
    %OpenApiSpex.Response{
      description: description,
      content: %{"application/json" => %OpenApiSpex.MediaType{schema: error_schema()}}
    }
  end

  # `KilnCMSWeb.ApiError`'s envelope.
  defp error_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        errors: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{
            type: :object,
            properties: %{
              status: %OpenApiSpex.Schema{type: :string, description: "Numeric HTTP status"},
              code: %OpenApiSpex.Schema{type: :string, description: "Stable token to branch on"},
              detail: %OpenApiSpex.Schema{type: :string}
            }
          }
        }
      }
    }
  end

  defp media_item_schema do
    nullable = fn type -> %OpenApiSpex.Schema{type: type, nullable: true} end

    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            type: %OpenApiSpex.Schema{type: :string, enum: ["media_item"]},
            id: %OpenApiSpex.Schema{type: :string, format: :uuid},
            attributes: %OpenApiSpex.Schema{
              type: :object,
              properties: %{
                filename: %OpenApiSpex.Schema{type: :string},
                content_type: nullable.(:string),
                kind: %OpenApiSpex.Schema{
                  type: :string,
                  enum: ["image", "video", "audio", "captions", "document"]
                },
                byte_size: nullable.(:integer),
                width: nullable.(:integer),
                height: nullable.(:integer),
                duration_seconds: nullable.(:number),
                url: nullable.(:string),
                variants: %OpenApiSpex.Schema{type: :object},
                alt: nullable.(:string),
                caption: nullable.(:string),
                decorative: %OpenApiSpex.Schema{type: :boolean},
                focal_x: %OpenApiSpex.Schema{type: :number},
                focal_y: %OpenApiSpex.Schema{type: :number},
                audience: %OpenApiSpex.Schema{type: :string},
                download_count: %OpenApiSpex.Schema{type: :integer},
                uploaded_by_id: %OpenApiSpex.Schema{type: :string, format: :uuid, nullable: true}
              }
            },
            relationships: %OpenApiSpex.Schema{type: :object},
            links: %OpenApiSpex.Schema{type: :object},
            meta: %OpenApiSpex.Schema{
              type: :object,
              properties: %{
                processing: %OpenApiSpex.Schema{
                  type: :boolean,
                  description:
                    "`true` while an A/V file's metadata strip is pending — `url` " <>
                      "serves nothing until it finishes"
                }
              }
            }
          }
        }
      }
    }
  end

  defp direct_upload_schema do
    %OpenApiSpex.Schema{
      type: :object,
      properties: %{
        data: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            token: %OpenApiSpex.Schema{type: :string},
            upload_url: %OpenApiSpex.Schema{type: :string, format: :uri},
            method: %OpenApiSpex.Schema{type: :string, enum: ["PUT"]},
            headers: %OpenApiSpex.Schema{
              type: :object,
              additionalProperties: %OpenApiSpex.Schema{type: :string},
              description: "Signed headers — send exactly these with the PUT"
            },
            expires_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
            max_bytes: %OpenApiSpex.Schema{type: :integer}
          }
        }
      }
    }
  end

  defp path_param(name, description) do
    %OpenApiSpex.Parameter{
      name: name,
      in: :path,
      required: true,
      description: description,
      schema: %OpenApiSpex.Schema{type: :string}
    }
  end

  defp query_param(name, description, opts \\ []) do
    %OpenApiSpex.Parameter{
      name: name,
      in: :query,
      required: false,
      description: description,
      schema: %OpenApiSpex.Schema{type: :string, enum: opts[:enum]}
    }
  end

  # Prefer the host the spec is being served from (so Swagger UI's "Try it out"
  # targets the right origin); fall back to the configured endpoint URL.
  defp servers(spec, %Plug.Conn{} = conn) do
    url = "#{conn.scheme}://#{conn.host}#{port_suffix(conn)}"
    [%OpenApiSpex.Server{url: url} | List.wrap(spec.servers)] |> Enum.uniq_by(& &1.url)
  end

  defp servers(spec, _conn) do
    case spec.servers do
      [_ | _] = servers ->
        servers

      _ ->
        [%OpenApiSpex.Server{url: KilnCMSWeb.Endpoint.url()}]
    end
  end

  defp port_suffix(%Plug.Conn{scheme: :http, port: 80}), do: ""
  defp port_suffix(%Plug.Conn{scheme: :https, port: 443}), do: ""
  defp port_suffix(%Plug.Conn{port: port}), do: ":#{port}"
end
