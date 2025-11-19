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
          machine_id: String.t() | nil,
          suspend_timer: reference() | nil
        }

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
  Suspends the machine.

  ## Returns
  - {:ok, machine_data} on success
  - {:error, reason} on failure
  """
  def suspend_machine(pid) do
    GenServer.call(pid, :suspend_machine, 20_000)
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
  def init(%{user_id: user_id, username: username, repo_name: repo_name} = _opts) do
    state = %{
      user_id: user_id,
      username: username,
      repo_name: repo_name,
      machine_id: nil,
      suspend_timer: nil
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
  def handle_call(:suspend_machine, _from, %{machine_id: nil} = state) do
    {:reply, {:error, :no_machine}, state}
  end

  def handle_call(:suspend_machine, _from, state) do
    {result, new_state} = suspend_machine_internal(state, "manual")
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:machine_request, action, args}, _from, %{machine_id: nil} = state) do
    case ensure_machine_sync(state) do
      {:ok, machine_id} ->
        new_state = %{state | machine_id: machine_id}
        result = machine_request_with_retry(machine_id, action, args)
        final_state = reset_suspend_timer(new_state)
        {:reply, result, final_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:machine_request, action, args}, _from, state) do
    result = machine_request_with_retry(state.machine_id, action, args)
    new_state = reset_suspend_timer(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_info(:suspend_machine, state) do
    case state.machine_id do
      nil ->
        {:noreply, state}

      _machine_id ->
        {_result, new_state} = suspend_machine_internal(state, "auto")
        {:noreply, new_state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp get_machine_file_path(state) do
    data_dir = Application.get_env(:eureka, :data_dir, ".")
    Path.join([data_dir, to_string(state.user_id), state.username, "#{state.repo_name}.json"])
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

  defp create_new_machine(state) do
    # First, check if a machine already exists for this username/repo
    case find_existing_machine(state) do
      {:ok, machine_id} ->
        Logger.info(
          "Found existing machine #{machine_id} for #{state.username}/#{state.repo_name}, reusing it"
        )

        # Save the machine ID to local storage for future use
        case save_machine_data(state, machine_id) do
          :ok ->
            {:ok, machine_id}

          {:error, reason} ->
            Logger.warning(
              "Failed to save machine data for #{machine_id}, but continuing: #{inspect(reason)}"
            )

            # Still return success since we have the machine
            {:ok, machine_id}
        end

      {:error, :not_found} ->
        # No existing machine found, create a new one
        Logger.info(
          "No existing machine found for #{state.username}/#{state.repo_name}, creating new one"
        )

        create_new_machine_internal(state)

      {:error, reason} ->
        Logger.warning(
          "Failed to check for existing machines: #{inspect(reason)}, creating new machine"
        )

        # If we can't list machines, fall back to creating a new one
        create_new_machine_internal(state)
    end
  end

  defp create_new_machine_internal(state) do
    machine_config = %{
      "username" => state.username,
      "repo_name" => state.repo_name
    }

    with {:ok, machine_data} <- Eureka.Fly.create_machine(machine_config),
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

  defp find_existing_machine(state) do
    case Eureka.Fly.list_machines() do
      {:ok, machines} when is_list(machines) ->
        # Look for a machine with matching USERNAME and REPO_NAME env vars
        matching_machine =
          Enum.find(machines, fn machine ->
            env = get_in(machine, ["config", "env"]) || %{}
            env["USERNAME"] == state.username and env["REPO_NAME"] == state.repo_name
          end)

        case matching_machine do
          %{"id" => machine_id} when is_binary(machine_id) ->
            {:ok, machine_id}

          _ ->
            {:error, :not_found}
        end

      {:ok, _} ->
        Logger.warning("Unexpected response from list_machines")
        {:error, :invalid_response}

      {:error, reason} ->
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

  defp suspend_machine_internal(state, reason) do
    case Eureka.Fly.suspend_machine(state.machine_id) do
      {:ok, _machine_data} ->
        log_message =
          case reason do
            "auto" ->
              "Auto-suspending machine #{state.machine_id} due to inactivity"

            "manual" ->
              "Suspended machine #{state.machine_id} for #{state.username}/#{state.repo_name}"
          end

        Logger.info(log_message)
        new_state = clear_suspend_timer(state)
        {{:ok, state.machine_id}, new_state}

      {:error, suspend_reason} ->
        Logger.error("Failed to suspend machine #{state.machine_id}: #{inspect(suspend_reason)}")
        new_state = clear_suspend_timer(state)
        {{:error, suspend_reason}, new_state}
    end
  end

  defp reset_suspend_timer(state) do
    state
    |> clear_suspend_timer()
    |> start_suspend_timer()
  end

  defp clear_suspend_timer(%{suspend_timer: timer} = state) when is_reference(timer) do
    Process.cancel_timer(timer)
    %{state | suspend_timer: nil}
  end

  defp clear_suspend_timer(state) do
    %{state | suspend_timer: nil}
  end

  defp start_suspend_timer(%{machine_id: nil} = state) do
    state
  end

  defp start_suspend_timer(state) do
    timer = Process.send_after(self(), :suspend_machine, 60_000)
    %{state | suspend_timer: timer}
  end

  defp ensure_machine_sync(state) do
    case load_machine_data(state) do
      {:ok, machine_id} ->
        case Eureka.Fly.start_machine(machine_id) do
          {:ok, _} ->
            {:ok, machine_id}

          {:error, reason} ->
            Logger.warning(
              "Failed to start machine #{machine_id}, creating new: #{inspect(reason)}"
            )

            create_new_machine(state)
        end

      {:error, :not_found} ->
        create_new_machine(state)

      {:error, reason} ->
        Logger.error("Failed to load machine data: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
