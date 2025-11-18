defmodule Eureka.Changes.CreateFlyMachineAndWriteFile do
  @moduledoc """
  A custom Ash change that creates a Fly.io machine and writes the repository data to a file.

  This change runs after the repository record is created and handles:
  1. Creating a Fly.io machine via API
  2. Updating the repository record with the machine_id
  3. Writing the repository data to a JSON file in the filesystem
  """

  use Ash.Resource.Change

  @doc """
  Executes the change logic.
  """
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(
      changeset,
      fn changeset, repository ->
        case create_fly_machine_and_write_file(repository, changeset, context) do
          {:ok, updated_repository} ->
            {:ok, updated_repository}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      opts
    )
  end

  @doc """
  Determines if this change is atomic. Returns false since we make external API calls.
  """
  def atomic(_), do: false

  # Private functions

  defp create_fly_machine_and_write_file(repository, _changeset, _context) do
    with {:ok, machine_data} <- create_fly_machine(repository),
         machine_id when is_binary(machine_id) <- extract_machine_id(machine_data),
         {:ok, updated_repository} <- update_repository_with_machine_id(repository, machine_id),
         :ok <- write_repository_file(updated_repository) do
      {:ok, updated_repository}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :no_machine_id_in_response}
      error -> {:error, error}
    end
  end

  defp create_fly_machine(repository) do
    # Create a simple machine configuration
    machine_config = %{
      "name" => "#{repository.user_id}-#{repository.username}-#{repository.name}"
    }

    case Eureka.Fly.create_machine(machine_config) do
      {:ok, machine_data} ->
        {:ok, machine_data}

      {:error, reason} ->
        {:error, {:fly_machine_creation_failed, reason}}
    end
  end

  defp extract_machine_id(machine_data) do
    case machine_data do
      %{"id" => machine_id} when is_binary(machine_id) -> machine_id
      _ -> nil
    end
  end

  defp update_repository_with_machine_id(repository, machine_id) do
    # Update the repository with the machine_id
    updated_repository = %{repository | machine_id: machine_id}
    {:ok, updated_repository}
  end

  defp write_repository_file(repository) do
    data_dir = Application.get_env(:eureka, :data_dir, ".")

    # Create the directory path: data_dir/user_id/username/name/
    dir_path =
      Path.join([
        data_dir,
        repository.user_id,
        repository.username,
        repository.name
      ])

    # Create directories if they don't exist
    case File.mkdir_p(dir_path) do
      :ok ->
        # Write the repository data to JSON file
        file_path = Path.join(dir_path, "#{repository.id}.json")
        file_content = Jason.encode!(repository, pretty: true)

        case File.write(file_path, file_content) do
          :ok -> :ok
          {:error, reason} -> {:error, {:file_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:directory_creation_failed, reason}}
    end
  end
end
