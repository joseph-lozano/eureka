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
    redirect(conn, to: "/#{username_or_org}/#{repository}")
  end
end
