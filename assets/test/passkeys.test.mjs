// The passkey step-up on /sign-in/verify (#2247, #2828) against a fake window
// and document: the block and its "you can also use a passkey" hint are
// shipped `hidden`, and only a browser with WebAuthn reveals them.
// Run: `npm test` in assets/.
import {test, afterEach} from "node:test"
import assert from "node:assert/strict"

import {initPasskeyStepUp} from "../js/passkeys.js"

const navigatorDescriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator")

function withWebAuthn(on) {
  globalThis.window = on ? {PublicKeyCredential: function () {}} : {}
  Object.defineProperty(globalThis, "navigator", {
    value: on ? {credentials: {}} : {},
    configurable: true,
    writable: true,
  })
}

afterEach(() => {
  delete globalThis.window
  if (navigatorDescriptor) Object.defineProperty(globalThis, "navigator", navigatorDescriptor)
  else delete globalThis.navigator
})

// Element stand-ins: just what `initPasskeyStepUp` touches.
function fakePage({button = true} = {}) {
  const parts = {
    "[data-role=passkey-step-up]": button ? {addEventListener: () => {}} : null,
    "[data-role=passkey-status]": {textContent: ""},
  }
  const block = {hidden: true, querySelector: (selector) => parts[selector]}
  const hint = {hidden: true}
  const root = {
    querySelectorAll: (selector) =>
      ({
        "[data-passkey-step-up]": [block],
        "[data-passkey-step-up-hint]": [hint],
      })[selector] || [],
  }
  return {root, block, hint}
}

test("with WebAuthn, reveals the passkey button and the hint beside the code", () => {
  withWebAuthn(true)
  const {root, block, hint} = fakePage()

  initPasskeyStepUp(root)

  assert.equal(block.hidden, false)
  assert.equal(hint.hidden, false)
})

test("without WebAuthn, the button and the hint stay hidden", () => {
  withWebAuthn(false)
  const {root, block, hint} = fakePage()

  initPasskeyStepUp(root)

  assert.equal(block.hidden, true)
  assert.equal(hint.hidden, true)
})

test("a block with no button reveals neither, so the hint never points at nothing", () => {
  withWebAuthn(true)
  const {root, block, hint} = fakePage({button: false})

  initPasskeyStepUp(root)

  assert.equal(block.hidden, true)
  assert.equal(hint.hidden, true)
})
