// Passkey (WebAuthn) client plumbing (#331).
//
// Two independent pieces:
//
//  * `PasskeyEnroll` — a LiveView hook for /editor/settings: the server pushes
//    the `navigator.credentials.create()` options ("passkey-register"), the
//    browser runs the platform ceremony, and the attestation goes back up as a
//    "passkey_attestation" event for server-side Wax verification.
//
//  * `PasskeySignIn` — a LiveView hook for the /sign-in page, which renders
//    the button hidden (`KilnCMSWeb.SignInLive`); the hook reveals it where
//    WebAuthn exists: POST /auth/passkey/options → discoverable credential
//    get() → POST /auth/passkey/verify → follow the redirect.
//
//  * `initPasskeyStepUp` — the same affordance on the second-factor prompt
//    (#2247), a dead page (`KilnCMSWeb.TwoFactorController`), so it is wired
//    on load rather than by a hook: POST /sign-in/verify/passkey/options →
//    get() limited to the account's own credentials → POST
//    /sign-in/verify/passkey → follow the redirect. A refusal's JSON says
//    whether to start over (`redirect_to`) or what to show (`error`).
//
// All binary fields cross the wire as unpadded base64url.

export const b64uToBuf = (s) => {
  const pad = "=".repeat((4 - (s.length % 4)) % 4)
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad)
  return Uint8Array.from(bin, (c) => c.charCodeAt(0)).buffer
}

export const bufToB64u = (buf) => {
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
  if (!response.ok) {
    // The refusal's JSON body rides on the error, for a caller that acts on
    // it (`stepUpWithPasskey`); a body that isn't JSON leaves it empty.
    const error = new Error(`passkey request failed: ${response.status}`)
    error.body = await response.json().catch(() => ({}))
    throw error
  }
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

// The passkey affordance on /sign-in. The markup is server-rendered, hidden,
// by `KilnCMSWeb.SignInLive` (#1681); this only reveals it where WebAuthn
// exists and wires the click. The hook's element carries
// `phx-update="ignore"`, so a later render cannot re-hide what this unhid.
export const PasskeySignIn = {
  mounted() {
    if (!supported()) return

    const block = this.el.querySelector("[data-role=passkey]")
    const button = this.el.querySelector("[data-role=passkey-sign-in]")
    const status = this.el.querySelector("[data-role=passkey-status]")
    if (!block || !button) return

    block.hidden = false
    button.addEventListener("click", () => {
      if (status) status.textContent = ""
      signInWithPasskey(status)
    })
  },
}

const stepUpWithPasskey = async (statusEl) => {
  try {
    const {publicKey} = await post("/sign-in/verify/passkey/options")

    const assertion = await navigator.credentials.get({
      publicKey: {
        ...publicKey,
        challenge: b64uToBuf(publicKey.challenge),
        allowCredentials: (publicKey.allowCredentials || []).map((credential) => ({
          ...credential,
          id: b64uToBuf(credential.id),
        })),
      },
    })

    const {redirect_to} = await post("/sign-in/verify/passkey", {
      credential_id: bufToB64u(assertion.rawId),
      authenticator_data: bufToB64u(assertion.response.authenticatorData),
      signature: bufToB64u(assertion.response.signature),
      client_data_json: bufToB64u(assertion.response.clientDataJSON),
    })

    window.location.assign(redirect_to)
  } catch (error) {
    const body = error?.body || {}

    // The pending sign-in is over (expired or redeemed): start again where
    // the server says, as the code form's redirect would.
    if (typeof body.redirect_to === "string") {
      window.location.assign(body.redirect_to)
      return
    }

    // The server's text when it sent one (a spent budget, a retry), else the
    // page's generic refusal: a cancelled ceremony or a network failure has
    // no body.
    if (statusEl) statusEl.textContent = body.error || statusEl.dataset.errorText
  }
}

// The passkey affordance on /sign-in/verify (#2247). The server renders it,
// hidden, only for an account that has a passkey and on a host where the
// ceremony can run; this reveals it where WebAuthn exists and wires the click.
export const initPasskeyStepUp = (root = document) => {
  if (!supported()) return

  let revealed = false

  root.querySelectorAll("[data-passkey-step-up]").forEach((block) => {
    const button = block.querySelector("[data-role=passkey-step-up]")
    const status = block.querySelector("[data-role=passkey-status]")
    if (!button) return

    block.hidden = false
    revealed = true
    button.addEventListener("click", () => {
      if (status) status.textContent = ""
      stepUpWithPasskey(status)
    })
  })

  // The "or use a passkey" line beside the code prompt: shown only with a
  // button it can point at.
  if (revealed) {
    root.querySelectorAll("[data-passkey-step-up-hint]").forEach((hint) => {
      hint.hidden = false
    })
  }
}
