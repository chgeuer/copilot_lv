defmodule CopilotLv.Sessions do
  use Ash.Domain

  resources do
    resource(CopilotLv.Sessions.Session)
    resource(CopilotLv.Sessions.Event)
    resource(CopilotLv.Sessions.UsageEntry)
    resource(CopilotLv.Sessions.Checkpoint)
    resource(CopilotLv.Sessions.SessionArtifact)
    resource(CopilotLv.Sessions.SessionTodo)
  end
end
