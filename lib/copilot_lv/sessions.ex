defmodule CopilotLv.Sessions do
  use Ash.Domain

  resources do
    resource(CopilotLv.Sessions.Session)
    resource(CopilotLv.Sessions.Event)
    resource(CopilotLv.Sessions.UsageEntry)
    resource(CopilotLv.Sessions.Checkpoint)
    resource(CopilotLv.Sessions.SessionArtifact)
    resource(CopilotLv.Sessions.ProjectDocument)
    resource(CopilotLv.Sessions.SessionTodo)
    resource(CopilotLv.Sessions.SessionFile)
    resource(CopilotLv.Sessions.SessionRef)
  end
end
