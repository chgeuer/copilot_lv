defmodule CopilotLv.AgentPermissions do
  @moduledoc """
  Defines permission options and defaults for each agent type.

  Each agent has its own set of permission controls that map to CLI flags
  or adapter metadata. This module provides:
  - Default permission values per agent
  - Human-readable labels and descriptions
  - Conversion from form params to session options
  """

  @doc """
  Returns the default permissions map for the given agent.
  """
  def defaults(:copilot) do
    %{
      "allow_all_tools" => true,
      "allow_all_paths" => true,
      "allow_all_urls" => true
    }
  end

  def defaults(:claude) do
    %{
      "permission_mode" => "bypass_permissions"
    }
  end

  def defaults(:codex) do
    %{
      "approval_policy" => "on-request",
      "sandbox" => "workspace-write",
      "full_auto" => true
    }
  end

  def defaults(:gemini) do
    %{
      "approval_mode" => "yolo",
      "sandbox" => false
    }
  end

  def defaults(:pi), do: %{}
  def defaults(_), do: %{}

  @doc """
  Returns the permission option definitions for rendering in the UI.
  Each entry is a map with :key, :type, :label, :description, and type-specific fields.
  """
  def options(:copilot) do
    [
      %{
        key: "allow_all_tools",
        type: :toggle,
        label: "Allow All Tools",
        description: "Permit the agent to use any tool without prompting"
      },
      %{
        key: "allow_all_paths",
        type: :toggle,
        label: "Allow All Paths",
        description: "Permit file access to any path on the filesystem"
      },
      %{
        key: "allow_all_urls",
        type: :toggle,
        label: "Allow All URLs",
        description: "Permit network requests to any URL"
      }
    ]
  end

  def options(:claude) do
    [
      %{
        key: "permission_mode",
        type: :select,
        label: "Permission Mode",
        description: "Controls how Claude handles tool permissions",
        choices: [
          {"Bypass All (no prompts)", "bypass_permissions"},
          {"Accept Edits (auto-approve file edits)", "accept_edits"},
          {"Auto (Claude decides)", "auto"},
          {"Default (prompt for everything)", "default"},
          {"Plan (read-only planning first)", "plan"},
          {"Don't Ask (tools proceed silently)", "dont_ask"}
        ]
      }
    ]
  end

  def options(:codex) do
    [
      %{
        key: "full_auto",
        type: :toggle,
        label: "Full Auto",
        description:
          "Low-friction mode: auto-approve on-request + workspace-write sandbox. Overrides the settings below."
      },
      %{
        key: "approval_policy",
        type: :select,
        label: "Approval Policy",
        description: "When the model requires human approval before executing a command",
        choices: [
          {"On Request (model decides)", "on-request"},
          {"Untrusted Only (only trusted commands auto-run)", "untrusted"},
          {"Never (fully autonomous)", "never"}
        ]
      },
      %{
        key: "sandbox",
        type: :select,
        label: "Sandbox Mode",
        description: "Sandbox policy for model-generated shell commands",
        choices: [
          {"Workspace Write (safe default)", "workspace-write"},
          {"Read Only", "read-only"},
          {"Full Access (⚠ dangerous)", "danger-full-access"}
        ]
      }
    ]
  end

  def options(:gemini) do
    [
      %{
        key: "approval_mode",
        type: :select,
        label: "Approval Mode",
        description: "Controls when Gemini asks for tool approval",
        choices: [
          {"YOLO (auto-approve everything)", "yolo"},
          {"Auto Edit (auto-approve file edits only)", "auto_edit"},
          {"Default (prompt for approval)", "default"},
          {"Plan (read-only mode)", "plan"}
        ]
      },
      %{
        key: "sandbox",
        type: :toggle,
        label: "Sandbox",
        description: "Run in sandboxed environment"
      }
    ]
  end

  def options(:pi), do: []
  def options(_), do: []

  @doc """
  Converts form permission params to the keyword option format
  expected by SessionRegistry.create_session.
  """
  def from_params(agent, params) when is_map(params) do
    case agent do
      :copilot ->
        %{
          allow_all_tools: params["allow_all_tools"] == "true",
          allow_all_paths: params["allow_all_paths"] == "true",
          allow_all_urls: params["allow_all_urls"] == "true"
        }

      :claude ->
        %{
          permission_mode:
            String.to_existing_atom(params["permission_mode"] || "bypass_permissions")
        }

      :codex ->
        full_auto = params["full_auto"] == "true"

        %{
          full_auto: full_auto,
          approval_policy: params["approval_policy"] || "on-request",
          sandbox: params["sandbox"] || "workspace-write"
        }

      :gemini ->
        %{
          approval_mode: params["approval_mode"] || "yolo",
          sandbox: params["sandbox"] == "true"
        }

      _ ->
        %{}
    end
  end

  def from_params(_, _), do: %{}
end
