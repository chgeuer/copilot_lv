defmodule CopilotLv.AskUserBroker do
  @moduledoc """
  Broker for `ask_user` tool calls from Copilot external tools.

  Holds pending ask_user requests and unblocks callers when the user
  responds via the LiveView modal.
  """
  use GenServer

  @timeout :timer.minutes(5)

  defstruct pending: %{}

  # ── Public API ──

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Submit an ask_user request. Blocks until the user responds or timeout.

  Called by the SessionServer (in a Task). Returns `{:ok, response}` or `{:error, :timeout}`.
  """
  def request(request_id, session_id, question, choices) do
    GenServer.call(
      __MODULE__,
      {:request, request_id, session_id, question, choices},
      @timeout + 5_000
    )
  end

  @doc """
  Submit a user response to a pending ask_user request.

  Called by the LiveView when the user answers.
  """
  def respond(request_id, response) do
    GenServer.cast(__MODULE__, {:respond, request_id, response})
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:request, request_id, session_id, _question, _choices}, from, state) do
    timer_ref = Process.send_after(self(), {:request_timeout, request_id}, @timeout)

    pending =
      Map.put(state.pending, request_id, %{
        from: from,
        session_id: session_id,
        timer_ref: timer_ref
      })

    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_cast({:respond, request_id, response}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from, timer_ref: timer_ref}, pending} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, {:ok, response})
        {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_info({:request_timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from, session_id: session_id}, pending} ->
        GenServer.reply(from, {:error, :timeout})

        # Notify LiveView to dismiss the modal
        Phoenix.PubSub.broadcast(CopilotLv.PubSub, "session:#{session_id}", :ask_user_timeout)

        {:noreply, %{state | pending: pending}}
    end
  end
end
