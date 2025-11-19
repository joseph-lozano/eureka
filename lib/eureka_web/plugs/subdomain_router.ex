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
      Logger.debug("Workspace subdomain detected: #{conn.host}, proxying request")

      # Fetch session to ensure session_id is available
      conn = Plug.Conn.fetch_session(conn)

      # Ensure session_id exists (generate if needed)
      conn = EurekaWeb.Plugs.SessionPlug.call(conn, [])

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
        Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")
        EurekaWeb.ProxyUpstream.handle_error(error, conn)
    end
  end
end
