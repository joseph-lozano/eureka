defmodule Eureka.Fly do
  @moduledoc """
  Client for interacting with the Fly.io Machines API.
  """

  @doc """
  Creates a new machine in the specified Fly.io app.

  ## Parameters
  - app_name: The name of the Fly.io app to create the machine in
  - machine_config: Configuration map for the machine

  ## Returns
  - {:ok, machine_data} on success
  - {:error, reason} on failure
  """
  def create_machine(app_name, machine_config \\ %{}) do
    api_key = Application.get_env(:eureka, :fly_api)[:api_key]
    api_url = Application.get_env(:eureka, :fly_api)[:api_url]

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      url = "#{api_url}/apps/#{app_name}/machines"

      # Default machine configuration
      default_config = %{
        "config" => %{
          "auto_destroy" => true,
          "image" => "flyio/hellofly:latest",
          "guest" => %{
            "cpu_kind" => "shared",
            "cpus" => 1,
            "memory_mb" => 256
          },
          "restart" => %{
            "policy" => "no"
          },
          "services" => [
            %{
              "protocol" => "tcp",
              "internal_port" => 8080,
              "ports" => [
                %{
                  "port" => 80,
                  "handlers" => ["http"]
                }
              ]
            }
          ]
        },
        "region" => "iad",
        "skip_launch" => false
      }

      # Merge with provided config
      final_config = deep_merge(default_config, machine_config)

      headers = [
        {"Content-Type", "application/json"},
        {"Authorization", "Bearer #{api_key}"}
      ]

      case Req.post(url, json: final_config, headers: headers) do
        {:ok, %{status: 200} = response} ->
          {:ok, response.body}

        {:ok, %{status: status} = response} when status in 400..499 ->
          {:error, {:client_error, response.body}}

        {:ok, %{status: status} = response} when status in 500..599 ->
          {:error, {:server_error, response.body}}

        {:ok, response} ->
          {:error, {:unexpected_response, response}}

        {:error, reason} ->
          {:error, {:network_error, reason}}
      end
    end
  end

  @doc """
  Gets information about a specific machine.

  ## Parameters
  - app_name: The name of the Fly.io app
  - machine_id: The ID of the machine

  ## Returns
  - {:ok, machine_data} on success
  - {:error, reason} on failure
  """
  def get_machine(app_name, machine_id) do
    api_key = Application.get_env(:eureka, :fly_api)[:api_key]
    api_url = Application.get_env(:eureka, :fly_api)[:api_url]

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      url = "#{api_url}/apps/#{app_name}/machines/#{machine_id}"

      headers = [
        {"Authorization", "Bearer #{api_key}"}
      ]

      case Req.get(url, headers: headers) do
        {:ok, %{status: 200} = response} ->
          {:ok, response.body}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: status} = response} when status in 400..499 ->
          {:error, {:client_error, response.body}}

        {:ok, %{status: status} = response} when status in 500..599 ->
          {:error, {:server_error, response.body}}

        {:ok, response} ->
          {:error, {:unexpected_response, response}}

        {:error, reason} ->
          {:error, {:network_error, reason}}
      end
    end
  end

  # Helper function for deep merging maps
  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      if is_map(left_val) and is_map(right_val) do
        deep_merge(left_val, right_val)
      else
        right_val
      end
    end)
  end

  defp deep_merge(_left, right), do: right
end
