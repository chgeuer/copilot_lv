import assert from "node:assert/strict"
import test from "node:test"

import {rewriteFileImages} from "./file_images.mjs"

function image(attributes) {
  return {
    attributes,
    getAttribute(name) {
      return this.attributes[name] ?? null
    },
    setAttribute(name, value) {
      this.attributes[name] = value
    },
    removeAttribute(name) {
      delete this.attributes[name]
    }
  }
}

function container(...images) {
  return {
    querySelectorAll() {
      return images
    }
  }
}

test("defers unresolved local images without touching remote images", () => {
  const local = image({src: "/images/example.png"})
  const remote = image({src: "https://example.com/example.png"})

  rewriteFileImages(container(local, remote), {}, "gh_session")

  assert.deepEqual(local.attributes, {
    "data-file-image-src": "/images/example.png"
  })
  assert.deepEqual(remote.attributes, {
    src: "https://example.com/example.png"
  })
})

test("replaces deferred image sources with signed session routes", () => {
  const deferred = image({
    "data-file-image-src": "/images/example.png"
  })

  rewriteFileImages(
    container(deferred),
    {"/images/example.png": {token: "signed/token"}},
    "gh/session"
  )

  assert.deepEqual(deferred.attributes, {
    src: "/sessions/gh%2Fsession/files/signed%2Ftoken"
  })
})
