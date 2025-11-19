defmodule Eureka.MachineManager do
  @moduledoc """
  GenServer for managing Fly machine lifecycle.
  """

  use GenServer
  require Logger

  @type state :: %{
          session_id: String.t(),
          username: String.t(),
          repo_name: String.t(),
          machine_id: String.t() | nil,
          stop_timer: reference() | nil
        }

  @doc """
  Starts the MachineManager GenServer.

  ## Parameters
  - opts: Map containing :session_id, :username, :repo_name

  ## Returns
  - {:ok, pid} on success
  - {:error, reason} on failure
  """
  def start_link(%{session_id: session_id, username: username, repo_name: repo_name} = opts) do
    name = {:global, {session_id, username, repo_name}}

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @doc """
  Gets the current machine ID.

  ## Returns
  - {:ok, machine_id} if machine exists
  - {:error, :no_machine} if no machine is available
  """
  def get_machine_id(pid) do
    GenServer.call(pid, :get_machine_id, 20_000)
  end

  @doc """
  Ensures a machine is running, creating one if necessary.

  ## Returns
  - {:ok, machine_id} on success
  - {:error, reason} on failure
  """
  def ensure_machine(pid) do
    GenServer.call(pid, :ensure_machine, 20_000)
  end

  @doc """
  Stops the machine.

  ## Returns
  - {:ok, machine_data} on success
  - {:error, reason} on failure
  """
  def stop_machine(pid) do
    GenServer.call(pid, :stop_machine, 20_000)
  end

  @doc """
  Lists all sessions from the machine with automatic retry and machine restart.

  ## Returns
  - {:ok, sessions} on success
  - {:error, reason} on failure
  """
  def list_sessions(pid) do
    GenServer.call(pid, {:machine_request, :list_sessions, []}, 20_000)
  end

  # GenServer callbacks

  @impl true
  def init(%{session_id: session_id, username: username, repo_name: repo_name} = _opts) do
    state = %{
      session_id: session_id,
      username: username,
      repo_name: repo_name,
      machine_id: nil,
      stop_timer: nil
    }

    {:ok, state, {:continue, :create_machine}}
  end

  @impl true
  def handle_continue(:create_machine, state) do
    create_and_log_machine(state, "Created new machine")
  end

  @impl true
  def handle_call(:get_machine_id, _from, %{machine_id: nil} = state) do
    {:reply, {:error, :no_machine}, state}
  end

  def handle_call(:get_machine_id, _from, state) do
    {:reply, {:ok, state.machine_id}, state}
  end

  @impl true
  def handle_call(:ensure_machine, _from, %{machine_id: nil} = state) do
    case create_new_machine(state) do
      {:ok, machine_id} ->
        new_state = %{state | machine_id: machine_id}
        new_state = start_stop_timer(new_state)
        {:reply, {:ok, machine_id}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:ensure_machine, _from, state) do
    new_state = reset_stop_timer(state)
    {:reply, {:ok, state.machine_id}, new_state}
  end

  @impl true
  def handle_call(:stop_machine, _from, %{machine_id: nil} = state) do
    {:reply, {:error, :no_machine}, state}
  end

  def handle_call(:stop_machine, _from, state) do
    {result, new_state} = stop_machine_internal(state, "manual")
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:machine_request, action, args}, _from, %{machine_id: nil} = state) do
    case ensure_machine_sync(state) do
      {:ok, machine_id} ->
        new_state = %{state | machine_id: machine_id}
        result = machine_request_with_retry(machine_id, action, args)
        final_state = reset_stop_timer(new_state)
        {:reply, result, final_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:machine_request, action, args}, _from, state) do
    result = machine_request_with_retry(state.machine_id, action, args)
    new_state = reset_stop_timer(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_info(:stop_machine, state) do
    case state.machine_id do
      nil ->
        {:noreply, state}

      _machine_id ->
        {_result, new_state} = stop_machine_internal(state, "auto")
        {:noreply, new_state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp create_and_log_machine(state, log_message) do
    case create_new_machine(state) do
      {:ok, machine_id} ->
        new_state = %{state | machine_id: machine_id}
        Logger.info("#{log_message} #{machine_id} for #{state.username}/#{state.repo_name}")

        new_state = start_stop_timer(new_state)

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error(
          "Failed to create machine for #{state.username}/#{state.repo_name}: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  defp create_new_machine(state) do
    machine_config = %{
      "username" => state.username,
      "repo_name" => state.repo_name
    }

    case Eureka.Fly.create_machine(machine_config) do
      {:ok, machine_data} ->
        machine_id = machine_data["id"]
        {:ok, machine_id}

      {:error, reason} ->
        Logger.error("Failed to create machine: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp machine_request_with_retry(machine_id, action, args) do
    case apply_with_timeout(Eureka.Fly, action, [machine_id | args], 5000) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:network_error, %Req.TransportError{reason: :nxdomain}}} ->
        handle_network_error_and_retry(machine_id, action, args)

      {:error, :timeout} ->
        handle_network_error_and_retry(machine_id, action, args)

      error ->
        error
    end
  end

  defp apply_with_timeout(module, function, args, timeout) do
    task = Task.async(fn -> apply(module, function, args) end)

    try do
      Task.await(task, timeout)
    catch
      :exit, {:timeout, _} ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp handle_network_error_and_retry(machine_id, action, args) do
    case Eureka.Fly.start_machine(machine_id) do
      {:ok, _} ->
        Logger.info("Started machine #{machine_id}, retrying #{action}")

        should_retry = fn
          {:network_error, %Req.TransportError{reason: :nxdomain}} -> true
          :timeout -> true
          _ -> false
        end

        request_fun = fn ->
          apply_with_timeout(Eureka.Fly, action, [machine_id | args], 10000)
        end

        Eureka.Backoff.with_retry_conditional(request_fun, should_retry, 4, 1000, 2)

      {:error, start_reason} ->
        Logger.warning("Failed to start machine #{machine_id}: #{inspect(start_reason)}")
        {:error, {:network_error, %Req.TransportError{reason: :nxdomain}}}
    end
  end

  defp stop_machine_internal(state, reason) do
    case Eureka.Fly.stop_machine(state.machine_id) do
      {:ok, _machine_data} ->
        log_message =
          case reason do
            "auto" ->
              "Auto-stopping machine #{state.machine_id} due to inactivity"

            "manual" ->
              "Stopped machine #{state.machine_id} for #{state.username}/#{state.repo_name}"
          end

        Logger.info(log_message)
        new_state = clear_stop_timer(state)
        {{:ok, state.machine_id}, new_state}

      {:error, stop_reason} ->
        Logger.error("Failed to stop machine #{state.machine_id}: #{inspect(stop_reason)}")
        new_state = clear_stop_timer(state)
        {{:error, stop_reason}, new_state}
    end
  end

  defp reset_stop_timer(state) do
    state
    |> clear_stop_timer()
    |> start_stop_timer()
  end

  defp clear_stop_timer(%{stop_timer: timer} = state) when is_reference(timer) do
    Process.cancel_timer(timer)
    %{state | stop_timer: nil}
  end

  defp clear_stop_timer(state) do
    %{state | stop_timer: nil}
  end

  defp start_stop_timer(%{machine_id: nil} = state) do
    state
  end

  defp start_stop_timer(state) do
    timer = Process.send_after(self(), :stop_machine, :timer.minutes(30))
    %{state | stop_timer: timer}
  end

  defp ensure_machine_sync(state) do
    create_new_machine(state)
  end
end
