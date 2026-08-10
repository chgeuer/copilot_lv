const URI_SCHEME_RE = /^[a-z][a-z\d+.-]*:/i
const LOCALHOST_HTTP_RE = /^https?:\/\/localhost(?::\d+)?(?:\/|$)/i

function localFileImageSource(source) {
  if (typeof source !== "string" || source === "") return false
  if (LOCALHOST_HTTP_RE.test(source)) return true

  return !URI_SCHEME_RE.test(source) && !source.startsWith("//")
}

export function rewriteFileImages(container, tokenMap, sessionId) {
  if (!sessionId) return

  for (const image of container.querySelectorAll("img[data-file-image-src], img[src]")) {
    const source =
      image.getAttribute("data-file-image-src") ||
      image.getAttribute("src")
    const entry = tokenMap?.[source]

    if (entry) {
      image.removeAttribute("data-file-image-src")
      image.setAttribute(
        "src",
        `/sessions/${encodeURIComponent(sessionId)}/files/${encodeURIComponent(entry.token)}`
      )
    } else if (localFileImageSource(source)) {
      image.setAttribute("data-file-image-src", source)
      image.removeAttribute("src")
    }
  }
}
