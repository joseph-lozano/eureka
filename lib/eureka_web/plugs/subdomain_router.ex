defmodule EurekaWeb.Plugs.SubdomainRouter do
  @moduledoc """
  Routes workspace subdomain requests to the reverse proxy.

  Intercepts requests to workspace subdomains (e.g., sst--opencode.localhost)
  and proxies them to the appropriate machine, bypassing the main Phoenix router.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    if workspace_subdomain?(conn.host) do
      Logger.debug("Workspace subdomain detected: #{conn.host}, proxying to machine")

      # Fetch session first (required for WorkspaceSessionPlug)
      conn = Plug.Conn.fetch_session(conn)

      # Ensure workspace_session_id exists (generate if needed)
      conn = EurekaWeb.Plugs.WorkspaceSessionPlug.call(conn, [])

      proxy_to_machine(conn)
    else
      # Not a workspace subdomain, continue to Phoenix router
      conn
    end
  end

  defp workspace_subdomain?(host) when is_binary(host) do
    # Check if host contains "--" which indicates a workspace subdomain
    # e.g., "sst--opencode.localhost" or "username--repo.eureka.dev"
    String.contains?(host, "--")
  end

  defp workspace_subdomain?(_), do: false

  defp proxy_to_machine(conn) do
    try do
      # Build upstream URL
      upstream_url = EurekaWeb.ProxyUpstream.build_from_subdomain(conn)

      # Use our custom streaming proxy
      conn = EurekaWeb.Plugs.StreamingProxy.call(conn, upstream_url)

      # Halt to prevent further processing by Phoenix router
      halt(conn)
    rescue
      error ->
        Logger.error("Proxy error in proxy_to_machine: #{inspect(error)}")

        # Redirect back to main page
        redirect_to_main_page(conn)
    end
  end

  defp redirect_to_main_page(conn) do
    # Parse subdomain to get username/repo for redirect
    case parse_subdomain(conn.host) do
      {username, repository} ->
        host = Application.get_env(:eureka, :host)
        port = Application.get_env(:eureka, EurekaWeb.Endpoint)[:http][:port] || 4000

        redirect_url =
          case host do
            h when h in ["localhost", "eureka.local"] ->
              "http://#{host}:#{port}/#{username}/#{repository}"

            host when is_binary(host) ->
              "https://#{host}/#{username}/#{repository}"

            _ ->
              "http://eureka.local:#{port}/#{username}/#{repository}"
          end

        Logger.info("Redirecting to main page: #{redirect_url}")

        conn
        |> Phoenix.Controller.redirect(external: redirect_url)
        |> halt()

      nil ->
        # Couldn't parse subdomain, just send error
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(502, "Bad Gateway")
        |> halt()
    end
  end

  defp parse_subdomain(host) when is_binary(host) do
    case String.split(host, ".") do
      [subdomain | rest] when length(rest) >= 1 ->
        case String.split(subdomain, "--") do
          [username, repository] -> {username, repository}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_subdomain(_), do: nil
end
