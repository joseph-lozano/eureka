defmodule EurekaWeb.ProxyUpstream do
  @moduledoc """
  Builds upstream URLs for proxying requests to OpenCode Web machines.
  Handles machine lifecycle and error states.
  """

  require Logger

  @doc """
  Builds the upstream URL from path parameters.

  Extracts username and repository from /:username/:repository path,
  starts/ensures the machine is running, and returns the upstream URL for proxying.
  """
  def build_from_path(conn) do
    username = conn.path_params["username"]
    repository = conn.path_params["repository"]
    session_id = conn.assigns.workspace_session_id

    Logger.debug("Building upstream for #{username}/#{repository} (session: #{session_id})")

    {:ok, pid} =
      Eureka.MachineManager.start_link(%{
        session_id: session_id,
        username: username,
        repo_name: repository
      })

    case Eureka.MachineManager.ensure_machine(pid) do
      {:ok, machine_id} ->
        api_config = Application.get_env(:eureka, :fly_api)
        app_name = api_config[:app_name]

        upstream = "http://#{machine_id}.vm.#{app_name}.internal:8080"
        Logger.info("Proxying #{username}/#{repository} to #{upstream}")

        upstream

      {:error, reason} ->
        Logger.error("Failed to ensure machine for #{username}/#{repository}: #{inspect(reason)}")

        raise "Machine not available: #{inspect(reason)}"
    end
  end

  @doc """
  Builds the upstream URL from the subdomain in the Host header.

  Extracts username and repository from the subdomain (e.g., sst--opencode.eureka.dev),
  starts/ensures the machine is running, and returns the upstream URL for proxying.
  """
  def build_from_subdomain(conn) do
    # Check if this is a workspace subdomain first
    unless String.contains?(conn.host, "--") do
      raise "Not a workspace subdomain: #{conn.host}"
    end

    session_id = conn.assigns.workspace_session_id

    case parse_subdomain(conn.host) do
      {username, repository} ->
        Logger.info("ProxyUpstream - session_id: #{session_id}, #{username}/#{repository}")

        {:ok, pid} =
          Eureka.MachineManager.start_link(%{
            session_id: session_id,
            username: username,
            repo_name: repository
          })

        case Eureka.MachineManager.ensure_machine(pid) do
          {:ok, machine_id} ->
            api_config = Application.get_env(:eureka, :fly_api)
            app_name = api_config[:app_name]

            upstream = "http://#{machine_id}.vm.#{app_name}.internal:8080"
            Logger.debug("Proxying #{username}/#{repository} to #{upstream}")

            upstream

          {:error, reason} ->
            Logger.error(
              "Failed to ensure machine for #{username}/#{repository}: #{inspect(reason)}"
            )

            raise "Machine not available: #{inspect(reason)}"
        end

      nil ->
        # Not a workspace subdomain - pass through to Phoenix routes
        Logger.debug("No workspace subdomain found in host: #{conn.host}")
        raise "Invalid subdomain format: #{conn.host}"
    end
  end

  # Parses subdomain from host header to extract username and repository.
  #
  # Examples:
  #   - "sst--opencode.eureka.dev" → {"sst", "opencode"}
  #   - "my-user--my-repo.eureka.dev" → {"my-user", "my-repo"}
  #   - "sst--opencode.localhost" → {"sst", "opencode"}
  #   - "www.eureka.dev" → nil (main site)
  #   - "eureka.dev" → nil (apex domain)
  defp parse_subdomain(host) when is_binary(host) do
    case String.split(host, ".") do
      # Match workspace subdomains: ["sst--opencode", "eureka", "dev"]
      [subdomain | rest] when length(rest) >= 1 ->
        # Reject main site
        if subdomain == "www" do
          nil
        else
          # Split subdomain by double dash
          case String.split(subdomain, "--") do
            [username, repository] -> {username, repository}
            _ -> nil
          end
        end

      # Apex domain or invalid
      _ ->
        nil
    end
  end

  defp parse_subdomain(_), do: nil
end
