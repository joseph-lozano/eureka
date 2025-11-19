defmodule Eureka.Fly do
  @moduledoc """
  Client for interacting with the Fly.io Machines API.
  """

  @doc """
  Creates a new machine in the Fly.io app.

  ## Parameters
  - username: GitHub username or organization
  - repo_name: Repository name
  - machine_config: Additional configuration map for the machine (optional)

  ## Returns
  - {:ok, machine_data} on success
  - {:error, reason} on failure
  """
  def create_machine(username, repo_name, machine_config \\ %{}) do
    api_config = Application.get_env(:eureka, :fly_api)
    api_key = api_config[:api_key]
    api_url = api_config[:api_url]
    app_name = api_config[:app_name]

    if is_nil(api_key) or is_nil(app_name) do
      {:error, :missing_config}
    else
      url = "#{api_url}/apps/#{app_name}/machines"

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
          ],
          "env" => %{
            "USERNAME" => username,
            "REPO_NAME" => repo_name
          }
        },
        "region" => "iad",
        "skip_launch" => false
      }

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
  Stops a machine in the Fly.io app.

  ## Parameters
  - machine_id: The ID of the machine to stop

  ## Returns
  - {:ok, machine_data} on success
  - {:error, reason} on failure
  """
  def stop_machine(machine_id) do
    api_config = Application.get_env(:eureka, :fly_api)
    api_key = api_config[:api_key]
    api_url = api_config[:api_url]
    app_name = api_config[:app_name]

    if is_nil(api_key) or is_nil(app_name) do
      {:error, :missing_config}
    else
      url = "#{api_url}/apps/#{app_name}/machines/#{machine_id}/stop"

      headers = [
        {"Content-Type", "application/json"},
        {"Authorization", "Bearer #{api_key}"}
      ]

      case Req.post(url, headers: headers) do
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
  Starts a machine in the Fly.io app.

  ## Parameters
  - machine_id: The ID of the machine to start

  ## Returns
  - {:ok, machine_data} on success
  - {:error, reason} on failure
  """
  def start_machine(machine_id) do
    api_config = Application.get_env(:eureka, :fly_api)
    api_key = api_config[:api_key]
    api_url = api_config[:api_url]
    app_name = api_config[:app_name]

    if is_nil(api_key) or is_nil(app_name) do
      {:error, :missing_config}
    else
      url = "#{api_url}/apps/#{app_name}/machines/#{machine_id}/start"

      headers = [
        {"Content-Type", "application/json"},
        {"Authorization", "Bearer #{api_key}"}
      ]

      case Req.post(url, headers: headers) do
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
  Lists all machines in the Fly.io app.

  ## Returns
  - {:ok, machines} on success, where machines is a list of machine data maps
  - {:error, reason} on failure
  """
  def list_machines do
    api_config = Application.get_env(:eureka, :fly_api)
    api_key = api_config[:api_key]
    api_url = api_config[:api_url]
    app_name = api_config[:app_name]

    if is_nil(api_key) or is_nil(app_name) do
      {:error, :missing_config}
    else
      url = "#{api_url}/apps/#{app_name}/machines"

      headers = [
        {"Authorization", "Bearer #{api_key}"}
      ]

      case Req.get(url, headers: headers) do
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
  - opts: Options for the request (optional)

  ## Returns
  - {:ok, sessions} on success
  - {:error, reason} on failure

  ## Examples
      iex> Eureka.Fly.list_sessions("machine_123")
      {:ok, [%{"id" => "ses_abc123", "title" => "My Session"}]}
  """
  def list_sessions(machine_id, opts \\ []) do
    make_request(:get, machine_id, "/session", nil, opts)
  end

  @doc """
  Creates a new session.

  ## Parameters
  - machine_id: The ID of the machine to create session on
  - session_data: Map containing session data (parentID, title, etc.)
  - opts: Options for the request (optional)

  ## Returns
  - {:ok, session_id} on success
  - {:error, reason} on failure

  ## Examples
      iex> Eureka.Fly.create_session("machine_123", %{"title" => "New Session"})
      {:ok, "ses_def456"}
  """
  def create_session(machine_id, session_data \\ %{}, opts \\ []) do
    case make_request(:post, machine_id, "/session", session_data, opts) do
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
  - opts: Options for the request (optional)

  ## Returns
  - {:ok, %{id: message_id, text: message_text}} on success
  - {:error, reason} on failure

  ## Examples
      iex> Eureka.Fly.create_message("machine_123", "ses_abc123", %{
      ...>   "parts" => [%{"type" => "text", "text" => "Hello"}]
      ...> })
      {:ok, %{id: "msg_ghi789", text: "Hello"}}
  """
  def create_message(machine_id, session_id, message_data, opts \\ []) do
    case make_request(:post, machine_id, "/session/#{session_id}/message", message_data, opts) do
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
  Lists all messages in a session, extracting only text content with role.

  ## Parameters
  - machine_id: The ID of the machine
  - session_id: The ID of the session
  - opts: Options for the request (optional)

  ## Returns
  - {:ok, messages} on success
  - {:error, reason} on failure

  ## Examples
      iex> Eureka.Fly.list_messages("machine_123", "ses_abc123")
      {:ok, [%{role: "user", text: "Hello"}, %{role: "assistant", text: "Hi there!"}]}
  """
  def list_messages(machine_id, session_id, opts \\ []) do
    case make_request(:get, machine_id, "/session/#{session_id}/message", nil, opts) do
      {:ok, messages} ->
        text_messages =
          messages
          |> Enum.map(fn message ->
            text_part =
              message["parts"]
              |> Enum.find(fn part -> part["type"] == "text" end)

            %{
              role: message["info"]["role"],
              text: if(text_part, do: text_part["text"], else: "")
            }
          end)

        {:ok, text_messages}

      error ->
        error
    end
  end

  defp make_request(method, machine_id, path, body, opts \\ []) do
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

      default_options = [
        headers: headers,
        connect_options: [transport_opts: [inet6: true]]
      ]

      default_options =
        if body, do: Keyword.put(default_options, :json, body), else: default_options

      final_options = Keyword.merge(default_options, opts)

      request = Req.new(method: method, url: url) |> Req.merge(final_options)

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
