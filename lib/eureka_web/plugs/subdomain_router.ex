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
      Logger.debug("Cookies: #{inspect(conn.cookies)}")
      Logger.debug("Request cookies header: #{inspect(get_req_header(conn, "cookie"))}")

      # Run auth and check if user is authenticated
      conn = EurekaWeb.Plugs.AuthPlug.call(conn, [])

      Logger.debug("Current user after auth: #{inspect(conn.assigns[:current_user])}")

      # Check if user is authenticated before proxying
      if conn.assigns[:current_user] do
        proxy_to_machine(conn)
      else
        # Redirect to login
        redirect_to_login(conn)
      end
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

  defp redirect_to_login(conn) do
    Logger.info("Redirecting unauthenticated user to login from #{conn.host}")

    # Build the login URL on the main domain
    login_url = build_login_url(conn)

    conn
    |> Phoenix.Controller.redirect(external: login_url)
    |> halt()
  end

  # Builds the login URL on the main domain
  # For subdomains like sst--opencode.localhost, redirects to localhost
  # For subdomains like sst--opencode.eureka.dev, redirects to eureka.dev
  defp build_login_url(conn) do
    # Get the base domain (without the workspace subdomain)
    base_host =
      case String.split(conn.host, ".") do
        [_subdomain | rest] when length(rest) >= 1 ->
          # e.g., "sst--opencode.localhost" -> "localhost"
          # e.g., "sst--opencode.eureka.dev" -> "eureka.dev"
          Enum.join(rest, ".")

        _ ->
          # Fallback to current host
          conn.host
      end

    # Build the login URL
    scheme = if conn.scheme == :https, do: "https", else: "http"
    port = if conn.port in [80, 443], do: "", else: ":#{conn.port}"

    "#{scheme}://#{base_host}#{port}/auth/github"
  end

  defp proxy_to_machine(conn) do
    # Build upstream URL
    upstream_url = EurekaWeb.ProxyUpstream.build_from_subdomain(conn)

    # Use our custom streaming proxy
    conn = EurekaWeb.Plugs.StreamingProxy.call(conn, upstream_url)

    # Halt to prevent further processing by Phoenix router
    halt(conn)
  end
end
