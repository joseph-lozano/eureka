defmodule EurekaWeb.PageController do
  use EurekaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
