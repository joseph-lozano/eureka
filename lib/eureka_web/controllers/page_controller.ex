defmodule EurekaWeb.PageController do
  use EurekaWeb, :controller
  import Phoenix.Component, only: [to_form: 1]

  def home(conn, _params) do
    repo_form = to_form(%{"username_or_org" => "", "repository" => ""})

    conn
    |> assign(:repo_form, repo_form)
    |> render(:home)
  end

  def navigate(conn, %{"username_or_org" => username_or_org, "repository" => repository}) do
    # Build subdomain URL for workspace
    subdomain_url = build_workspace_url(username_or_org, repository)
    redirect(conn, external: subdomain_url)
  end

  # Build workspace subdomain URL based on environment
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
end
