defmodule CopilotLvWeb.FileViewer do
  @moduledoc """
  Cryptographically signed file path tokens for secure file viewing.

  Generates opaque tokens for file paths found in event content so that
  only server-verified paths can be viewed — prevents arbitrary filesystem
  enumeration even from an authenticated client.
  """

  @salt "file-viewer-v1"
  @max_age 86_400

  @doc "Sign a file path into an opaque token."
  def sign_path(endpoint, path) when is_binary(path) do
    Phoenix.Token.sign(endpoint, @salt, path)
  end

  @doc "Verify a signed token, returning `{:ok, path}` or `{:error, reason}`."
  def verify_token(endpoint, token) when is_binary(token) do
    Phoenix.Token.verify(endpoint, @salt, token, max_age: @max_age)
  end

  @doc """
  Validate that `path` is within one of the allowed base directories.
  Prevents path traversal attacks even for valid tokens.
  """
  def path_allowed?(path, allowed_bases) when is_binary(path) and is_list(allowed_bases) do
    expanded = Path.expand(path)

    Enum.any?(allowed_bases, fn base ->
      base = Path.expand(to_string(base))
      String.starts_with?(expanded, base <> "/") or expanded == base
    end)
  end

  @doc """
  Read a file if it exists and is a regular file (not a directory, device, etc.).
  Returns `{:ok, content}` or `{:error, reason}`.
  """
  def read_file(path) do
    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, %{type: :regular, size: size}} when size <= 2_000_000 ->
        File.read(expanded)

      {:ok, %{type: :regular}} ->
        {:error, :file_too_large}

      {:ok, _} ->
        {:error, :not_a_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Scan markdown text for file path references and return a map of `%{url => token}`.

  Detects patterns like:
  - `http://localhost:PORT/absolute/path/to/file.ext`
  - Markdown links with absolute paths like `[text](/home/user/file.ext)`
  """
  def scan_and_sign(endpoint, text) when is_binary(text) do
    # Match http://localhost:PORT/absolute-path patterns
    localhost_regex = ~r/https?:\/\/localhost:\d+(\/\S+?(?:\.\w{1,10}))(?=[)\s"'\]>]|$)/

    # Match bare absolute-path links: [text](/home/...) or [text](/tmp/...)
    abspath_regex = Regex.compile!("\\]\\((/(home|tmp|var|usr|etc|opt|mnt)/[^)\\s]+)\\)")

    localhost_tokens =
      localhost_regex
      |> Regex.scan(text)
      |> Enum.reduce(%{}, fn
        [full_url, file_path], acc ->
          token = sign_path(endpoint, file_path)
          Map.put(acc, full_url, %{token: token, path: file_path})

        _, acc ->
          acc
      end)

    abspath_tokens =
      abspath_regex
      |> Regex.scan(text)
      |> Enum.reduce(%{}, fn
        [_full, file_path | _], acc ->
          token = sign_path(endpoint, file_path)
          Map.put(acc, file_path, %{token: token, path: file_path})

        _, acc ->
          acc
      end)

    Map.merge(localhost_tokens, abspath_tokens)
  end

  def scan_and_sign(_endpoint, _non_binary), do: %{}

  @doc "Detect the language for syntax highlighting based on file extension."
  def detect_language(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".eex" -> "elixir"
      ".heex" -> "elixir"
      ".js" -> "javascript"
      ".ts" -> "javascript"
      ".jsx" -> "javascript"
      ".tsx" -> "javascript"
      ".json" -> "json"
      ".html" -> "html"
      ".xml" -> "xml"
      ".css" -> "css"
      ".md" -> "markdown"
      ".py" -> "python"
      ".rb" -> "ruby"
      ".sh" -> "bash"
      ".bash" -> "bash"
      ".yml" -> "yaml"
      ".yaml" -> "yaml"
      ".toml" -> "toml"
      ".rs" -> "rust"
      ".go" -> "go"
      ".cs" -> "csharp"
      _ -> "plaintext"
    end
  end
end
