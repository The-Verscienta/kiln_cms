// Passkey (WebAuthn) client plumbing (#331).
//
// Two independent pieces:
//
//  * `PasskeyEnroll` — a LiveView hook for /editor/settings: the server pushes
//    the `navigator.credentials.create()` options ("passkey-register"), the
//    browser runs the platform ceremony, and the attestation goes back up as a
//    "passkey_attestation" event for server-side Wax verification.
//
//  * `initPasskeySignIn` — progressive enhancement for the /sign-in page
//    (which is rendered by ash_authentication_phoenix, so we add the button
//    from JS rather than a template): POST /auth/passkey/options → discoverable
//    credential get() → POST /auth/passkey/verify → follow the redirect.
//
// All binary fields cross the wire as unpadded base64url.

const b64uToBuf = (s) => {
  const pad = "=".repeat((4 - (s.length % 4)) % 4)
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad)
  return Uint8Array.from(bin, (c) => c.charCodeAt(0)).buffer
}

const bufToB64u = (buf) => {
  // Chunked: spreading a large buffer into fromCharCode's arguments hits the
  // JS engine's argument limit (attestation objects can be multi-KB).
  const bytes = new Uint8Array(buf)
  let bin = ""
  for (let i = 0; i < bytes.length; i += 8192) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 8192))
  }
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const supported = () =>
  typeof window.PublicKeyCredential !== "undefined" && navigator.credentials

export const PasskeyEnroll = {
  mounted() {
    this.handleEvent("passkey-register", async ({publicKey, name}) => {
      if (!supported()) {
        this.pushEvent("passkey_error", {})
        return
      }

      try {
        const credential = await navigator.credentials.create({
          publicKey: {
            ...publicKey,
            challenge: b64uToBuf(publicKey.challenge),
            user: {...publicKey.user, id: b64uToBuf(publicKey.user.id)},
          },
        })

        this.pushEvent("passkey_attestation", {
          name,
          attestation_object: bufToB64u(credential.response.attestationObject),
          client_data_json: bufToB64u(credential.response.clientDataJSON),
        })
      } catch (_error) {
        this.pushEvent("passkey_error", {})
      }
    })
  },
}

const post = async (path, body) => {
  const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
  const response = await fetch(path, {
    method: "POST",
    headers: {"content-type": "application/json", "x-csrf-token": csrf},
    body: JSON.stringify(body || {}),
  })
  if (!response.ok) throw new Error(`passkey request failed: ${response.status}`)
  return response.json()
}

const signInWithPasskey = async (statusEl) => {
  try {
    const {publicKey} = await post("/auth/passkey/options")

    const assertion = await navigator.credentials.get({
      publicKey: {
        ...publicKey,
        challenge: b64uToBuf(publicKey.challenge),
      },
    })

    const {redirect_to} = await post("/auth/passkey/verify", {
      credential_id: bufToB64u(assertion.rawId),
      authenticator_data: bufToB64u(assertion.response.authenticatorData),
      signature: bufToB64u(assertion.response.signature),
      client_data_json: bufToB64u(assertion.response.clientDataJSON),
    })

    window.location.assign(redirect_to)
  } catch (_error) {
    if (statusEl) statusEl.textContent = statusEl.dataset.errorText
  }
}

export const initPasskeySignIn = () => {
  if (window.location.pathname !== "/sign-in" || !supported()) return

  // The sign-in form is rendered by ash_authentication_phoenix. Attach the
  // passkey affordance AFTER the LiveView root, not inside it — LiveView's
  // DOM patching removes unknown nodes from its own container on connect.
  const main = document.querySelector("[data-phx-main]")
  const wrap = document.createElement("div")
  wrap.className = "mx-auto mt-4 max-w-sm pb-8 text-center"
  // Deliberately NOT worded "Sign in …": the accessible name must not collide
  // with the password form's submit for /sign in/i selectors (e2e strict mode).
  wrap.innerHTML = `
    <button type="button" class="btn btn-default w-full" data-role="passkey-sign-in">
      Use a passkey
    </button>
    <p class="mt-2 text-xs opacity-60" data-role="passkey-status"
       data-error-text="Passkey sign-in failed — use another method."></p>
  `
  if (main) {
    main.insertAdjacentElement("afterend", wrap)
  } else {
    document.body.appendChild(wrap)
  }

  wrap
    .querySelector("[data-role=passkey-sign-in]")
    .addEventListener("click", () =>
      signInWithPasskey(wrap.querySelector("[data-role=passkey-status]"))
    )
}
