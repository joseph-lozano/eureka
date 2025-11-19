defmodule EurekaWeb.PageController do
  use EurekaWeb, :controller
  import Phoenix.Component, only: [to_form: 1]
  require Logger

  def home(conn, _params) do
    repo_form = to_form(%{"username_or_org" => "", "repository" => ""})

    conn
    |> assign(:repo_form, repo_form)
    |> render(:home)
  end

  def navigate(conn, %{"username_or_org" => username_or_org, "repository" => repository}) do
    # Redirect to the workspace loading page (LiveView)
    redirect(conn, to: ~p"/#{username_or_org}/#{repository}")
  end
end
