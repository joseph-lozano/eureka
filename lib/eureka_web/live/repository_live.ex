defmodule EurekaWeb.RepositoryLive do
  use EurekaWeb, :live_view

  def mount(%{"username" => username, "repository" => repository}, _session, socket) do
    socket =
      assign(socket, username: username, repository: repository, machine_id: nil, error: nil)

    if connected?(socket) do
      start_machine_manager(socket)
    else
      {:ok, socket}
    end
  end

  defp start_machine_manager(socket) do
    repo_owner = socket.assigns.username
    repository = socket.assigns.repository

    with :ok <- validate_github_repo(repo_owner, repository),
         user_login <- fetch_user_login!(socket),
         {:ok, pid} <-
           Eureka.MachineManager.start_link(%{
             user_id: user_login,
             username: repo_owner,
             repo_name: repository
           }) do
      handle_machine_started(socket, pid)
    else
      {:error, {:already_started, pid}} ->
        handle_machine_started(socket, pid)

      {:error, reason} when is_binary(reason) ->
        socket = assign(socket, error: "Invalid repository: #{reason}")
        {:ok, socket}

      {:error, reason} ->
        socket = assign(socket, error: "Failed to start machine manager: #{inspect(reason)}")
        {:ok, socket}
    end
  end

  defp handle_machine_started(socket, pid) do
    case Eureka.MachineManager.get_machine_id(pid) do
      {:ok, machine_id} ->
        socket = assign(socket, machine_manager: pid, machine_id: machine_id)
        {:ok, socket}

      {:error, _reason} ->
        socket = assign(socket, machine_manager: pid)
        {:ok, socket}
    end
  end

  defp validate_github_repo(username, repository) do
    url = "https://api.github.com/repos/#{username}/#{repository}"

    headers = [
      {"Accept", "application/vnd.github.v3+json"},
      {"User-Agent", "Eureka-App"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: repo_data}} ->
        if repo_data["private"] do
          {:error, "repository is private"}
        else
          :ok
        end

      {:ok, %{status: 404}} ->
        {:error, "repository not found"}

      {:ok, %{status: status}} when status in 400..499 ->
        {:error, "client error (#{status})"}

      {:ok, %{status: status}} when status in 500..599 ->
        {:error, "server error (#{status})"}

      {:error, reason} ->
        {:error, "request failed: #{inspect(reason)}"}
    end
  end

  defp fetch_user_login!(socket) do
    current_user = socket.assigns[:current_user]

    cond do
      is_nil(current_user) ->
        raise "User not authenticated"

      is_nil(current_user["login"]) or current_user["login"] == "" ->
        raise "GitHub login not found"

      true ->
        current_user["login"]
    end
  end
end
