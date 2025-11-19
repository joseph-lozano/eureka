defmodule EurekaWeb.WorkspaceLive do
  use EurekaWeb, :live_view
  require Logger

  @max_attempts 6
  @ping_interval :timer.seconds(5)

  def mount(
        %{"username" => username, "repo" => repo},
        %{"workspace_session_id" => session_id} = _session,
        socket
      ) do
    if session_id do
      # Build subdomain URL for workspace
      subdomain_url = build_workspace_url(username, repo)

      socket =
        assign(socket,
          username: username,
          repo: repo,
          subdomain_url: subdomain_url,
          status: :loading,
          attempts: 0,
          max_attempts: @max_attempts,
          error_message: nil,
          machine_pid: nil,
          machine_id: nil
        )

      socket =
        if connected?(socket) do
          Logger.info("WorkspaceLive mount - session_id: #{session_id}, #{username}/#{repo}")

          # Start the machine manager (only on connected mount)
          {:ok, pid} =
            Eureka.MachineManager.start_link(%{
              session_id: session_id,
              username: username,
              repo_name: repo
            })

          # Try to get machine_id (might not exist yet)
          machine_id =
            case Eureka.MachineManager.get_machine_id(pid) do
              {:ok, id} -> id
              {:error, :no_machine} -> nil
            end

          # Schedule first ping (only on connected mount)
          Process.send_after(self(), :ping_machine, @ping_interval)

          assign(socket, machine_pid: pid, machine_id: machine_id)
        else
          socket
        end

      {:ok, socket}
    else
      {:ok,
       assign(socket,
         username: username,
         repo: repo,
         subdomain_url: nil,
         status: :error,
         attempts: 0,
         max_attempts: @max_attempts,
         error_message: "Session not found. Please refresh the page."
       )}
    end
  end

  def handle_info(:ping_machine, socket) do
    attempts = socket.assigns.attempts + 1

    # Get current machine_id (might have been created since mount)
    {machine_id, machine_error} =
      case socket.assigns.machine_id do
        nil ->
          case get_machine_info_from_manager(socket.assigns.machine_pid) do
            {:ok, id} -> {id, nil}
            {:error, reason} -> {nil, reason}
          end

        id ->
          {id, nil}
      end

    cond do
      # No machine ID yet and too many attempts
      is_nil(machine_id) && attempts >= @max_attempts ->
        Logger.error(
          "Failed to create machine for #{socket.assigns.username}/#{socket.assigns.repo} after #{attempts} attempts. " <>
            "Machine ID: #{inspect(machine_id)}, Error: #{inspect(machine_error)}"
        )

        error_msg =
          if machine_error do
            "Failed to create workspace: #{inspect(machine_error)}"
          else
            "Failed to create workspace. The machine may be taking longer than expected to start."
          end

        {:noreply,
         assign(socket,
           status: :error,
           attempts: attempts,
           error_message: error_msg
         )}

      # No machine ID yet, keep waiting
      is_nil(machine_id) ->
        Logger.debug(
          "Machine not created yet, waiting... (attempt #{attempts}). " <>
            "Error: #{inspect(machine_error)}"
        )

        Process.send_after(self(), :ping_machine, @ping_interval)
        {:noreply, assign(socket, attempts: attempts)}

      # Have machine ID, try pinging
      true ->
        case ping_machine_internal(machine_id) do
          :ok ->
            Logger.info(
              "Machine #{machine_id} is ready, redirecting to #{socket.assigns.subdomain_url}"
            )

            {:noreply,
             socket
             |> assign(status: :ready)
             |> redirect(external: socket.assigns.subdomain_url)}

          :error when attempts >= @max_attempts ->
            Logger.error("Failed to reach machine #{machine_id} after #{attempts} attempts")

            {:noreply,
             assign(socket,
               status: :error,
               attempts: attempts,
               error_message:
                 "Failed to start workspace. The machine may be taking longer than expected to boot."
             )}

          :error ->
            # Schedule next ping
            Process.send_after(self(), :ping_machine, @ping_interval)
            {:noreply, assign(socket, machine_id: machine_id, attempts: attempts)}
        end
    end
  end

  def handle_event("retry", _params, socket) do
    # Reset state and start pinging again
    Process.send_after(self(), :ping_machine, @ping_interval)

    {:noreply,
     assign(socket,
       status: :loading,
       attempts: 0,
       error_message: nil
     )}
  end

  defp ping_machine_internal(machine_id) do
    api_config = Application.get_env(:eureka, :fly_api)
    app_name = api_config[:app_name]
    url = "http://#{machine_id}.vm.#{app_name}.internal:8080/"

    Logger.debug("Pinging machine at #{url}")

    case Req.head(url,
           receive_timeout: 5000,
           retry: false,
           connect_options: [
             timeout: 5_000,
             transport_opts: [inet6: true]
           ]
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("Machine #{machine_id} responded with status #{status}")
        :ok

      {:ok, %{status: status}} ->
        Logger.debug("Machine returned status #{status}, retrying...")
        :error

      {:error, reason} ->
        Logger.debug("Failed to ping machine: #{inspect(reason)}")
        :error
    end
  end

  defp get_machine_info_from_manager(pid) when is_pid(pid) do
    case Eureka.MachineManager.get_machine_id(pid) do
      {:ok, machine_id} -> {:ok, machine_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_machine_info_from_manager(_), do: {:error, :no_pid}

  defp build_workspace_url(username, repository) do
    subdomain = "#{username}--#{repository}"

    # Get port from config
    port = Application.get_env(:eureka, EurekaWeb.Endpoint)[:http][:port] || 4000

    # Check if we're in production (has a real domain configured)
    case Application.get_env(:eureka, EurekaWeb.Endpoint)[:url][:host] do
      host when host in ["localhost", "eureka.local"] ->
        # Development: always use eureka.local for cookie sharing
        "http://#{subdomain}.eureka.local:#{port}/"

      host when is_binary(host) ->
        # Production: use configured host (e.g., eureka.dev)
        "https://#{subdomain}.#{host}/"

      _ ->
        # Fallback to eureka.local for development
        "http://#{subdomain}.eureka.local:#{port}/"
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-screen flex items-center justify-center">
        <div class="text-center max-w-md">
          <%= cond do %>
            <% @status == :loading -> %>
              <div class="flex flex-col items-center gap-6">
                <span class="loading loading-spinner loading-lg text-primary"></span>
                <div>
                  <h2 class="text-2xl font-bold mb-2">Spinning up your sandbox...</h2>
                  <p class="text-base-content/70">
                    Starting workspace for {@username}/{@repo}
                  </p>
                  <p class="text-sm text-base-content/50 mt-2">
                    Attempt {@attempts} of {@max_attempts}
                  </p>
                  <%= if Application.get_env(:eureka, :env) == :dev do %>
                    <%= if @machine_id do %>
                      <p class="text-xs text-base-content/40 mt-3 font-mono">
                        Machine: {@machine_id}
                      </p>
                      <p class="text-xs text-base-content/40 font-mono break-all">
                        Internal: {@machine_id}.vm.{Application.get_env(:eureka, :fly_api)[:app_name]}.internal:8080
                      </p>
                    <% else %>
                      <p class="text-xs text-base-content/40 mt-3">
                        Creating machine...
                      </p>
                    <% end %>
                  <% end %>
                </div>
              </div>
            <% @status == :ready -> %>
              <div class="flex flex-col items-center gap-4">
                <div class="text-success">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="h-16 w-16"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                </div>
                <div>
                  <h2 class="text-2xl font-bold mb-2">Workspace Ready!</h2>
                  <p class="text-base-content/70">Redirecting you now...</p>
                </div>
              </div>
            <% @status == :error -> %>
              <div class="alert alert-error">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="stroke-current shrink-0 h-6 w-6"
                  fill="none"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
                </svg>
                <div class="flex flex-col items-start">
                  <span class="font-bold">Failed to start workspace</span>
                  <span class="text-sm">{@error_message}</span>
                </div>
              </div>
              <div class="mt-4 flex gap-2 justify-center">
                <button class="btn btn-primary" phx-click="retry">
                  Retry
                </button>
                <.link href={~p"/"} class="btn btn-ghost">
                  Go Home
                </.link>
              </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
