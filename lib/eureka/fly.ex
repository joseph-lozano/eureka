defmodule Eureka.Fly do
  @moduledoc """
  Client for interacting with the Fly.io Machines API.
  """

  @doc """
  Creates a new machine in the Fly.io app.

  ## Parameters
  - machine_config: Configuration map for the machine

  ## Returns
  - {:ok, machine_data} on success
  - {:error, reason} on failure
  """
  def create_machine(machine_config \\ %{}) do
    api_config = Application.get_env(:eureka, :fly_api)
    api_key = api_config[:api_key]
    api_url = api_config[:api_url]
    app_name = api_config[:app_name]

    if is_nil(api_key) or is_nil(app_name) do
      {:error, :missing_config}
    else
      url = "#{api_url}/apps/#{app_name}/machines"

      # Default machine configuration
      default_config = %{
        "config" => %{
          "auto_destroy" => true,
          "image" => "jetpackjoe/opencode:latest",
          "guest" => %{
            "cpu_kind" => "shared",
            "cpus" => 1,
            "memory_mb" => 512
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

  @doc """
  Gets documentation from a running machine.

  ## Parameters
  - machine_id: The ID of the machine to get documentation from

  ## Returns
  - {:ok, doc_content} on success
  - {:error, reason} on failure

  ## Examples
      iex> Eureka.Fly.get_docs("machine_123")
      {:ok, %{"openapi" => "3.1.1", "info" => %{...}}}
  """
  def get_docs(machine_id) do
    make_request(:get, machine_id, "/doc", nil)
  end

  @doc """
  Lists all sessions.

  ## Parameters
  - machine_id: The ID of the machine to list sessions from

  ## Returns
  - {:ok, sessions} on success
  - {:error, reason} on failure

  ## Examples
      iex> Eureka.Fly.list_sessions("machine_123")
      {:ok, [%{"id" => "ses_abc123", "title" => "My Session"}]}
  """
  def list_sessions(machine_id) do
    make_request(:get, machine_id, "/session", nil)
  end

  @doc """
  Creates a new session.

  ## Parameters
  - machine_id: The ID of the machine to create session on
  - session_data: Map containing session data (parentID, title, etc.)

  ## Returns
  - {:ok, session_id} on success
  - {:error, reason} on failure

  ## Examples
      iex> Eureka.Fly.create_session("machine_123", %{"title" => "New Session"})
      {:ok, "ses_def456"}
  """
  def create_session(machine_id, session_data \\ %{}) do
    case make_request(:post, machine_id, "/session", session_data) do
      {:ok, session} ->
        {:ok, session["id"]}

      error ->
        error
    end
  end

  @doc """
  Creates a new message in a session.

  ## Parameters
  - machine_id: The ID of the machine
  - session_id: The ID of the session
  - message_data: Map containing message data (parts, model, etc.)

  ## Returns
  - {:ok, %{id: message_id, text: message_text}} on success
  - {:error, reason} on failure

  ## Examples
      iex> Eureka.Fly.create_message("machine_123", "ses_abc123", %{
      ...>   "parts" => [%{"type" => "text", "text" => "Hello"}]
      ...> })
      {:ok, %{id: "msg_ghi789", text: "Hello"}}
  """
  def create_message(machine_id, session_id, message_data) do
    case make_request(:post, machine_id, "/session/#{session_id}/message", message_data) do
      {:ok, message} ->
        text_part =
          message["parts"]
          |> Enum.find(fn part -> part["type"] == "text" end)

        text = if text_part, do: text_part["text"], else: ""

        {:ok,
         %{
           id: message["info"]["id"],
           text: text
         }}

      error ->
        error
    end
  end

  @doc """
  Lists all messages in a session, extracting only text content.

  ## Parameters
  - machine_id: The ID of the machine
  - session_id: The ID of the session

  ## Returns
  - {:ok, text_messages} on success
  - {:error, reason} on failure

  ## Examples
      iex> Eureka.Fly.list_messages("machine_123", "ses_abc123")
      {:ok, ["Hello world", "How are you?"]}
  """
  def list_messages(machine_id, session_id) do
    case make_request(:get, machine_id, "/session/#{session_id}/message", nil) do
      {:ok, messages} ->
        text_messages =
          messages
          |> Enum.flat_map(fn message ->
            message["parts"] || []
          end)
          |> Enum.filter(fn part ->
            part["type"] == "text"
          end)
          |> Enum.map(fn part ->
            part["text"]
          end)

        {:ok, text_messages}

      error ->
        error
    end
  end

  # Helper function for making HTTP requests with common error handling
  defp make_request(method, machine_id, path, body) do
    api_config = Application.get_env(:eureka, :fly_api)
    api_key = api_config[:api_key]
    app_name = api_config[:app_name]

    if is_nil(api_key) or is_nil(app_name) do
      {:error, :missing_config}
    else
      hostname = "#{machine_id}.vm.#{app_name}.internal"
      url = "http://#{hostname}:8080#{path}"

      headers = [
        {"Authorization", "Bearer #{api_key}"}
      ]

      options = [
        headers: headers,
        connect_options: [transport_opts: [inet6: true]]
      ]

      options = if body, do: Keyword.put(options, :json, body), else: options

      request = Req.new(method: method, url: url) |> Req.merge(options)

      case Req.request(request) do
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
