defmodule EurekaWeb.Plugs.WorkspaceSessionPlug do
  @moduledoc """
  Ensures a unique workspace_session_id exists via a custom cookie.

  This workspace_session_id is used to isolate machines per browser session and repository.
  The cookie is set with a wildcard domain (.eureka.local or .your-domain.com) so it's
  shared across the main domain and all subdomains.

  This solves the issue where Phoenix session cookies are not shared between
  eureka.local and sst--opencode.eureka.local, which was causing duplicate machines.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.cookies["workspace_session_id"] do
      nil ->
        # Generate a new workspace session ID
        session_id = generate_session_id()
        cookie_domain = get_cookie_domain()

        Logger.debug(
          "Generated new workspace_session_id: #{session_id}, domain: #{inspect(cookie_domain)}"
        )

        conn
        |> put_resp_cookie("workspace_session_id", session_id,
          domain: cookie_domain,
          max_age: 24 * 60 * 60,
          # 24 hours
          http_only: true,
          same_site: "Lax",
          secure: conn.scheme == :https
        )
        |> put_session(:workspace_session_id, session_id)
        |> assign(:workspace_session_id, session_id)

      session_id ->
        # Workspace session already exists
        conn
        |> put_session(:workspace_session_id, session_id)
        |> assign(:workspace_session_id, session_id)
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  defp get_cookie_domain do
    host = Application.get_env(:eureka, :host)

    case host do
      # Can't use wildcard domain on localhost - browser won't accept it
      "localhost" ->
        nil

      # Wildcard domain for eureka.local and all subdomains (*.eureka.local)
      "eureka.local" ->
        ".eureka.local"

      # Production: wildcard domain for custom domain (e.g., .eureka.dev)
      host when is_binary(host) ->
        ".#{host}"

      # Fallback
      _ ->
        ".eureka.local"
    end
  end
end
