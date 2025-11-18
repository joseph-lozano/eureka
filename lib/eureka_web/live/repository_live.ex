defmodule EurekaWeb.RepositoryLive do
  use EurekaWeb, :live_view

  def mount(%{"username" => username, "repository" => repository}, _session, socket) do
    {:ok, assign(socket, username: username, repository: repository)}
  end
end
