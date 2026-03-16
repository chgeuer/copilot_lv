import {marked} from "marked"
import hljs from "highlight.js/lib/core"
import elixir from "highlight.js/lib/languages/elixir"
import javascript from "highlight.js/lib/languages/javascript"
import json from "highlight.js/lib/languages/json"
import bash from "highlight.js/lib/languages/bash"
import xml from "highlight.js/lib/languages/xml"
import css from "highlight.js/lib/languages/css"
import diff from "highlight.js/lib/languages/diff"
import markdown from "highlight.js/lib/languages/markdown"
import python from "highlight.js/lib/languages/python"
import csharp from "highlight.js/lib/languages/csharp"

hljs.registerLanguage("elixir", elixir)
hljs.registerLanguage("javascript", javascript)
hljs.registerLanguage("json", json)
hljs.registerLanguage("bash", bash)
hljs.registerLanguage("shell", bash)
hljs.registerLanguage("html", xml)
hljs.registerLanguage("xml", xml)
hljs.registerLanguage("heex", xml)
hljs.registerLanguage("css", css)
hljs.registerLanguage("diff", diff)
hljs.registerLanguage("markdown", markdown)
hljs.registerLanguage("python", python)
hljs.registerLanguage("csharp", csharp)
hljs.registerLanguage("cs", csharp)

// Configure marked with highlight.js
marked.setOptions({
  highlight(code, lang) {
    if (lang && hljs.getLanguage(lang)) {
      return hljs.highlight(code, {language: lang}).value
    }
    return hljs.highlightAuto(code).value
  },
  breaks: true,
  gfm: true,
})

// Pattern for local file path links
// Matches: http://localhost:PORT/path/file.ext OR /home/user/path/file.ext
const LOCAL_FILE_LINK_RE = /^https?:\/\/localhost:\d+(\/\S+?\.\w{1,10})$/
const ABSPATH_LINK_RE = /^(\/(?:home|tmp|var|usr|etc|opt|mnt)\/\S+?\.\w{1,10})$/

// Extract line number from link text (e.g., "seed2.md:1275")
function extractLineFromText(text) {
  const m = text.match(/:(\d+)$/)
  return m ? parseInt(m[1], 10) : 0
}

// Rewrite local file links in rendered HTML to use signed tokens
function rewriteFileLinks(container, tokenMap, hook) {
  if (!tokenMap || Object.keys(tokenMap).length === 0) return

  const links = container.querySelectorAll("a[href]")
  for (const link of links) {
    if (link.dataset.fileToken) continue // already processed

    const href = link.getAttribute("href")

    // Try matching as localhost URL or absolute path
    let lookupKey = null
    const localhostMatch = href.match(LOCAL_FILE_LINK_RE)
    const abspathMatch = href.match(ABSPATH_LINK_RE)

    if (localhostMatch) {
      lookupKey = href // full URL is the key for localhost matches
    } else if (abspathMatch) {
      lookupKey = abspathMatch[1] // the absolute path is the key
    }

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

// Render markdown to HTML, adding copy buttons to code blocks
function renderMarkdown(md) {
  let html = marked.parse(md)
  // Wrap each <pre> block with a container that has a copy button
  html = html.replace(/<pre><code([^>]*)>([\s\S]*?)<\/code><\/pre>/g,
    (match, attrs, code) => {
      // Decode HTML entities for the copy data
      const decoded = code.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&').replace(/&quot;/g, '"')
      const escapedForAttr = decoded.replace(/"/g, '&quot;')
      return `<div class="relative group">
        <button class="copy-btn absolute top-2 right-2 opacity-0 group-hover:opacity-100 transition-opacity btn btn-ghost btn-xs" data-copy-text="${escapedForAttr}">📋</button>
        <pre><code${attrs}>${code}</code></pre>
      </div>`
    })
  return html
}

// Hook: renders markdown content and supports copy-to-clipboard
export const MarkdownContent = {
  mounted() {
    this._fileTokens = {}
    this.render()
    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest(".copy-btn")
      if (btn) {
        const text = btn.getAttribute("data-copy-text")
        navigator.clipboard.writeText(text).then(() => {
          btn.textContent = "✓"
          setTimeout(() => { btn.textContent = "📋" }, 1500)
        })
      }
    })
    this.handleEvent("file_tokens", ({ tokens }) => {
      Object.assign(this._fileTokens, tokens)
      // Re-render from scratch so links have their original hrefs restored
      this.render()
    })
  },
  updated() {
    this.render()
  },
  render() {
    const raw = this.el.getAttribute("data-markdown") || this.el.textContent
    if (raw) {
      this.el.innerHTML = renderMarkdown(raw)
      rewriteFileLinks(this.el, this._fileTokens, this)
    }
  }
}

// Hook: copy full raw markdown to clipboard
export const CopyMarkdown = {
  mounted() {
    this.el.addEventListener("click", () => {
      const targetId = this.el.getAttribute("data-target")
      const target = document.getElementById(targetId)
      if (target) {
        const raw = target.getAttribute("data-markdown") || target.textContent
        navigator.clipboard.writeText(raw).then(() => {
          const orig = this.el.textContent
          this.el.textContent = "✓ Copied"
          setTimeout(() => { this.el.textContent = orig }, 1500)
        })
      }
    })
  }
}

// Hook: user message with plaintext/markdown toggle
export const UserMessage = {
  mounted() {
    this._mdMode = false
    this._raw = this.el.getAttribute("data-markdown") || ""

    // Find toggle button by data-target matching this element's id
    const toggleBtn = this.el.closest(".chat-bubble")?.querySelector(`.toggle-md-btn[data-target="${this.el.id}"]`)
    if (toggleBtn) {
      toggleBtn.addEventListener("click", () => {
        this._mdMode = !this._mdMode
        this.render()
        toggleBtn.textContent = this._mdMode ? "Aa" : "Md"
        toggleBtn.title = this._mdMode ? "Show plain text" : "Show as markdown"
      })
      toggleBtn.textContent = "Md"
      toggleBtn.title = "Show as markdown"
    }

    this.render()
  },
  updated() {
    this._raw = this.el.getAttribute("data-markdown") || ""
    this.render()
  },
  render() {
    if (this._mdMode) {
      this.el.classList.remove("whitespace-pre-wrap")
      this.el.innerHTML = renderMarkdown(this._raw)
      this.el.classList.add("markdown-body")
    } else {
      this.el.classList.add("whitespace-pre-wrap")
      this.el.classList.remove("markdown-body")
      this.el.innerHTML = renderPlainTextWithMentions(this._raw)
    }
  }
}

// Render plain text with styled @file mentions
function renderPlainTextWithMentions(text) {
  const escaped = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  return escaped.replace(/(^|\s)(@\S+)/g, (match, space, mention) => {
    return space + '<span class="mention-pill">' + mention + '</span>'
  })
}
