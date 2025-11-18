defmodule Eureka.MachineManager do
  @moduledoc """
  GenServer for managing Fly machine lifecycle.
  """

  use GenServer
  require Logger

  @type state :: %{
          user_id: String.t(),
          username: String.t(),
          repo_name: String.t(),
          machine_id: String.t() | nil
        }

  # Client API

  @doc """
  Starts the MachineManager GenServer.

  ## Parameters
  - opts: Map containing :user_id, :username, :repo_name

  ## Returns
  - {:ok, pid} on success
  - {:error, reason} on failure
  """
  def start_link(%{user_id: user_id, username: username, repo_name: repo_name} = opts) do
    name = {:global, {user_id, username, repo_name}}

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
    GenServer.call(pid, :get_machine_id)
  end

  @doc """
  Ensures a machine is running, creating one if necessary.

  ## Returns
  - {:ok, machine_id} on success
  - {:error, reason} on failure
  """
  def ensure_machine(pid) do
    GenServer.call(pid, :ensure_machine)
  end

  @doc """
  Stops the machine.

  ## Returns
  - {:ok, machine_data} on success
  - {:error, reason} on failure
  """
  def stop_machine(pid) do
    GenServer.call(pid, :stop_machine)
  end

  @doc """
  Lists all sessions from the machine with automatic retry and machine restart.

  ## Returns
  - {:ok, sessions} on success
  - {:error, reason} on failure
  """
  def list_sessions(pid) do
    GenServer.call(pid, {:machine_request, :list_sessions, []})
  end

  # GenServer callbacks

  @impl true
  def init(%{user_id: user_id, username: username, repo_name: repo_name} = _opts) do
    state = %{
      user_id: user_id,
      username: username,
      repo_name: repo_name,
      machine_id: nil
    }

    {:ok, state, {:continue, :load_or_create_machine}}
  end

  @impl true
  def handle_continue(:load_or_create_machine, state) do
    case load_machine_data(state) do
      {:ok, machine_id} ->
        start_or_create_machine(state, machine_id)

      {:error, :not_found} ->
        create_and_log_machine(state, "Created new machine")

      {:error, reason} ->
        Logger.error(
          "Failed to load machine data for #{state.username}/#{state.repo_name}: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  defp start_or_create_machine(state, machine_id) do
    case Eureka.Fly.start_machine(machine_id) do
      {:ok, _machine_data} ->
        new_state = %{state | machine_id: machine_id}

        Logger.info(
          "Started existing machine #{machine_id} for #{state.username}/#{state.repo_name}"
        )

        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning(
          "Failed to start machine #{machine_id}, creating new machine: #{inspect(reason)}"
        )

        create_and_log_machine(state, "Created new machine")
    end
  end

  defp create_and_log_machine(state, log_message) do
    case create_new_machine(state) do
      {:ok, machine_id} ->
        new_state = %{state | machine_id: machine_id}
        Logger.info("#{log_message} #{machine_id} for #{state.username}/#{state.repo_name}")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error(
          "Failed to create machine for #{state.username}/#{state.repo_name}: #{inspect(reason)}"
        )

        {:noreply, state}
    end
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
        {:reply, {:ok, machine_id}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:ensure_machine, _from, state) do
    {:reply, {:ok, state.machine_id}, state}
  end

  @impl true
  def handle_call(:stop_machine, _from, %{machine_id: nil} = state) do
    {:reply, {:error, :no_machine}, state}
  end

  def handle_call(:stop_machine, _from, state) do
    case Eureka.Fly.suspend_machine(state.machine_id) do
      {:ok, _machine_data} ->
        Logger.info(
          "Stopped machine #{state.machine_id} for #{state.username}/#{state.repo_name}"
        )

        {:reply, {:ok, state.machine_id}, state}

      {:error, reason} ->
        Logger.error("Failed to stop machine #{state.machine_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:machine_request, _action, _args}, _from, %{machine_id: nil} = state) do
    {:reply, {:error, :no_machine}, state}
  end

  def handle_call({:machine_request, action, args}, _from, state) do
    result = machine_request_with_retry(state.machine_id, action, args)
    {:reply, result, state}
  end

  # Private functions

  defp get_machine_file_path(state) do
    data_dir = Application.get_env(:eureka, :data_dir, ".")
    Path.join([data_dir, state.user_id, state.username, "#{state.repo_name}.json"])
  end

  defp load_machine_data(state) do
    file_path = get_machine_file_path(state)

    with {:ok, content} <- File.read(file_path),
         {:ok, %{"machine_id" => machine_id}} when is_binary(machine_id) <- Jason.decode(content) do
      {:ok, machine_id}
    else
      {:error, :enoent} ->
        {:error, :not_found}

      {:ok, data} ->
        Logger.warning("Invalid machine data format in #{file_path}: #{inspect(data)}")
        {:error, :invalid_format}

      {:error, reason} ->
        Logger.error("Failed to decode machine data from #{file_path}: #{inspect(reason)}")
        {:error, :decode_error}

      reason ->
        Logger.error("Failed to read machine data from #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_new_machine(state) do
    with {:ok, machine_data} <- Eureka.Fly.create_machine(),
         machine_id = machine_data["id"],
         :ok <- save_machine_data(state, machine_id) do
      {:ok, machine_id}
    else
      {:error, reason} ->
        Logger.error("Failed to create machine: #{inspect(reason)}")
        {:error, reason}

      reason ->
        Logger.error("Failed to save machine data: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp save_machine_data(state, machine_id) do
    file_path = get_machine_file_path(state)
    dir_path = Path.dirname(file_path)

    with :ok <- File.mkdir_p(dir_path),
         machine_data = %{"machine_id" => machine_id},
         {:ok, json_content} <- Jason.encode(machine_data, pretty: true) do
      File.write(file_path, json_content)
    else
      {:error, reason} ->
        {:error, {:mkdir_error, reason}}

      reason ->
        {:error, {:encode_error, reason}}
    end
  end

  defp machine_request_with_retry(machine_id, action, args) do
    # Try to start machine once if we get network error
    case apply(Eureka.Fly, action, [machine_id | args]) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:network_error, %Req.TransportError{reason: :nxdomain}}} ->
        case Eureka.Fly.start_machine(machine_id) do
          {:ok, _} ->
            Logger.info("Started machine #{machine_id}, retrying #{action}")
            # Now retry with backoff
            Eureka.Backoff.with_retry(
              fn -> apply(Eureka.Fly, action, [machine_id | args]) end,
              4,
              1000,
              2
            )

          {:error, start_reason} ->
            Logger.warning("Failed to start machine #{machine_id}: #{inspect(start_reason)}")
            {:error, {:network_error, %Req.TransportError{reason: :nxdomain}}}
        end

      error ->
        error
    end
  end
end
