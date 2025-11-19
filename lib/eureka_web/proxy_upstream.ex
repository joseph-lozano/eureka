defmodule EurekaWeb.ProxyUpstream do
  @moduledoc """
  Builds upstream URLs for proxying requests to OpenCode Web machines.
  Handles machine lifecycle and error states.
  """

  require Logger

  defmodule NotAWorkspaceError do
    defexception [:message, :host]
  end

  @doc """
  Builds the upstream URL from path parameters.

  Extracts username and repository from /:username/:repository path,
  starts/ensures the machine is running, and returns the upstream URL for proxying.
  """
  def build_from_path(conn) do
    username = conn.path_params["username"]
    repository = conn.path_params["repository"]
    session_id = get_session_id(conn)

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
      raise NotAWorkspaceError, message: "Not a workspace subdomain", host: conn.host
    end

    session_id = get_session_id(conn)

    case parse_subdomain(conn.host) do
      {username, repository} ->
        Logger.debug(
          "Building upstream for subdomain: #{username}/#{repository} (session: #{session_id})"
        )

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
            Logger.error(
              "Failed to ensure machine for #{username}/#{repository}: #{inspect(reason)}"
            )

            raise "Machine not available: #{inspect(reason)}"
        end

      nil ->
        # Not a workspace subdomain - pass through to Phoenix routes
        Logger.debug("No workspace subdomain found in host: #{conn.host}")
        raise NotAWorkspaceError, message: "Invalid subdomain format", host: conn.host
    end
  end

  @doc """
  Handles proxy errors with a user-friendly error page.

  Returns a 502 Bad Gateway with instructions to retry, typically shown
  when a machine is starting up.
  """
  def handle_error(%NotAWorkspaceError{}, conn) do
    # Not a workspace subdomain - this should never happen because
    # the catch-all route should only match workspace subdomains
    # Return 404 to avoid confusing proxy errors
    Logger.debug("Not a workspace subdomain: #{conn.host}")

    conn
    |> Plug.Conn.put_status(404)
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(
      404,
      "<html><body><h1>404 Not Found</h1><p>This is not a valid workspace subdomain.</p></body></html>"
    )
  end

  def handle_error(error, conn) do
    Logger.error("Proxy error: #{inspect(error)}")

    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(502, error_page_html())
  end

  defp get_session_id(conn) do
    case Plug.Conn.get_session(conn, :session_id) do
      nil ->
        Logger.error("No session_id found in session - this should not happen")
        raise "No session_id in session"

      session_id ->
        session_id
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

  defp error_page_html do
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Starting Workspace</title>
        <style>
          body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            max-width: 600px;
            margin: 100px auto;
            text-align: center;
            padding: 20px;
            background: #f9fafb;
          }
          .container {
            background: white;
            padding: 40px;
            border-radius: 12px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
          }
          h1 { color: #1f2937; margin-bottom: 16px; }
          p { color: #6b7280; line-height: 1.6; margin-bottom: 24px; }
          .button {
            display: inline-block;
            padding: 12px 24px;
            background: #3b82f6;
            color: white;
            text-decoration: none;
            border-radius: 6px;
            font-weight: 500;
            transition: background 0.2s;
          }
          .button:hover { background: #2563eb; }
          .spinner {
            border: 3px solid #e5e7eb;
            border-top: 3px solid #3b82f6;
            border-radius: 50%;
            width: 40px;
            height: 40px;
            animation: spin 1s linear infinite;
            margin: 20px auto;
          }
          @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
          }
        </style>
        <script>
          // Auto-retry after 3 seconds
          setTimeout(() => window.location.reload(), 3000);
        </script>
      </head>
      <body>
        <div class="container">
          <div class="spinner"></div>
          <h1>Starting your workspace...</h1>
          <p>Your development machine is spinning up. This usually takes 10-30 seconds.</p>
          <p style="color: #9ca3af; font-size: 14px;">The page will automatically retry in 3 seconds.</p>
          <a href="javascript:window.location.reload()" class="button">Retry Now</a>
        </div>
      </body>
    </html>
    """
  end
end
