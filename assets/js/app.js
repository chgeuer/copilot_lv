// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/copilot_lv"
import topbar from "../vendor/topbar"

import {
  MarkdownContent, CopyMarkdown, UserMessage, ToolGroup, AutoScroll,
  configureSessionViewer
} from "jido_tool_renderers/session_viewer_hooks"
import {XtermSession} from "../vendor/xterm_hook"

// ── CtrlClick hook for multi-select rows ──

const CtrlClick = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      const row = e.target.closest("tr[data-select-id]")
      if (!row) return
      if (e.target.closest("a[href]") || e.target.closest("button")) return
      e.preventDefault()
      e.stopPropagation()
      this.pushEvent("toggle_select", {
        id: row.dataset.selectId,
        ctrl: (e.ctrlKey || e.metaKey) ? "true" : "false"
      })
    })
  }
}

// ── copilot_lv-specific: file link rewriting ──

const LOCAL_FILE_LINK_RE = /^https?:\/\/localhost:\d+(\/\S+?\.\w{1,10})$/
const ABSPATH_LINK_RE = /^(\/(?:home|tmp|var|usr|etc|opt|mnt)\/\S+?\.\w{1,10})$/

function extractLineFromText(text) {
  const m = text.match(/:(\d+)$/)
  return m ? parseInt(m[1], 10) : 0
}

function rewriteFileLinks(container, tokenMap, hook) {
  if (!tokenMap || Object.keys(tokenMap).length === 0) return
  const links = container.querySelectorAll("a[href]")
  for (const link of links) {
    if (link.dataset.fileToken) continue
    const href = link.getAttribute("href")
    let lookupKey = null
    const localhostMatch = href.match(LOCAL_FILE_LINK_RE)
    const abspathMatch = href.match(ABSPATH_LINK_RE)
    if (localhostMatch) lookupKey = href
    else if (abspathMatch) lookupKey = abspathMatch[1]
    if (!lookupKey) continue
    const entry = tokenMap[lookupKey]
    if (!entry) continue
    const line = extractLineFromText(link.textContent)
    link.removeAttribute("href")
    link.style.cursor = "pointer"
    link.classList.add("file-viewer-link")
    link.title = `View ${entry.path}${line ? `:${line}` : ""}`
    link.dataset.fileToken = entry.token
    link.dataset.fileLine = line
    link.addEventListener("click", (e) => {
      e.preventDefault()
      hook.pushEvent("view_file", { token: entry.token, line })
    })
  }
}

configureSessionViewer({
  postRender(container, hook) {
    rewriteFileLinks(container, hook._fileTokens, hook)
  }
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, AutoScroll, MarkdownContent, CopyMarkdown, UserMessage, ToolGroup, XtermSession, CtrlClick},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

