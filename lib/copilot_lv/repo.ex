defmodule CopilotLv.Repo do
  use AshSqlite.Repo, otp_app: :copilot_lv

  def installed_extensions do
    []
  end
end
