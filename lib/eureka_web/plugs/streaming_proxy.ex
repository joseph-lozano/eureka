defmodule EurekaWeb.Plugs.StreamingProxy do
  @moduledoc """
  A simple streaming reverse proxy using Req.

  Supports infinite timeouts for streaming responses like SSE.
  """

  import Plug.Conn
  require Logger

  def call(conn, upstream_url) do
    # Build the full URL with path and query string
    url = build_url(upstream_url, conn)

    session_id =
      conn.assigns[:workspace_session_id] || get_session(conn, "workspace_session_id") ||
        "unknown"

    {username, repo} = parse_host_info(conn.host)

    Logger.info(
      "Proxying #{conn.method} #{conn.request_path} - Session: #{session_id}, Repo: #{username}/#{repo}"
    )

    Logger.debug("Proxy headers: #{inspect(proxy_headers(conn))}")

    # Store method and path in process dictionary for logging in stream_chunks
    Process.put(:proxy_method, conn.method)
    Process.put(:proxy_path, conn.request_path)

    body = read_request_body(conn)

    # Make the request with streaming enabled
    result =
      Req.request(
        method: String.downcase(conn.method) |> String.to_atom(),
        url: url,
        headers: proxy_headers(conn),
        body: body,
        into: :self,
        receive_timeout: :infinity,
        connect_options: [
          timeout: 60_000,
          transport_opts: [inet6: true]
        ]
      )

    case result do
      {:ok, response} ->
        Logger.debug("Received response: status=#{response.status}")
        Logger.debug("Response headers: #{inspect(response.headers)}")
        Logger.debug("Response body type: #{inspect(response.body.__struct__ || :binary)}")
        stream_response(conn, response)

      {:error, reason} ->
        Logger.error("Proxy request failed: #{inspect(reason)}")
        Logger.error("Failed URL: #{url}")

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(
          502,
          "<h1>502 Bad Gateway</h1><p>Failed to connect to upstream service: #{inspect(reason)}</p>"
        )
    end
  end

  defp build_url(upstream_url, conn) do
    # Remove leading slash from request_path if present
    path = String.trim_leading(conn.request_path, "/")

    # Build full URL
    base = String.trim_trailing(upstream_url, "/")
    url = "#{base}/#{path}"

    # Add query string if present
    if conn.query_string != "" do
      "#{url}?#{conn.query_string}"
    else
      url
    end
  end

  defp proxy_headers(conn) do
    # Forward most headers, but skip some that shouldn't be proxied
    skip_headers = ["host", "connection"]

    conn.req_headers
    |> Enum.reject(fn {name, _value} -> name in skip_headers end)
  end

  defp read_request_body(conn) do
    # Check if body was already read/parsed by Plug.Parsers
    cond do
      # If body_params is set and not empty, we have parsed JSON/form data
      conn.body_params != %Plug.Conn.Unfetched{} and map_size(conn.body_params) > 0 ->
        # Re-encode the parsed params as JSON
        Jason.encode!(conn.body_params)

      # Try to read the raw body
      true ->
        case Plug.Conn.read_body(conn, length: 10_000_000) do
          {:ok, body, _conn} ->
            body

          {:more, partial, conn} ->
            # Handle large bodies by reading all chunks
            read_more_body(partial, conn)

          {:error, _reason} ->
            ""
        end
    end
  end

  defp read_more_body(acc, conn) do
    case Plug.Conn.read_body(conn, length: 10_000_000) do
      {:ok, body, _conn} -> acc <> body
      {:more, partial, conn} -> read_more_body(acc <> partial, conn)
      {:error, _reason} -> acc
    end
  end

  defp stream_response(conn, %{status: status, headers: headers, body: body}) do
    method = Process.get(:proxy_method, "UNKNOWN")
    path = Process.get(:proxy_path, "UNKNOWN")

    # Set response status and headers
    conn = %{conn | resp_headers: []}
    conn = conn |> put_status(status)

    # Forward headers from upstream
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        # Convert header value to string if it's a list
        header_value =
          case value do
            [v] when is_binary(v) -> v
            v when is_binary(v) -> v
            v when is_list(v) -> Enum.join(v, ", ")
            v -> to_string(v)
          end

        put_resp_header(conn, String.downcase(name), header_value)
      end)

    # Stream the response body
    conn = send_chunked(conn, status)

    case body do
      chunks when is_list(chunks) ->
        # Body is already complete
        Logger.debug("[#{method} #{path}] Body is a list with #{length(chunks)} chunks")

        Enum.reduce_while(chunks, conn, fn chunk, conn ->
          case chunk(conn, chunk) do
            {:ok, conn} -> {:cont, conn}
            {:error, :closed} -> {:halt, conn}
          end
        end)

      body when is_binary(body) ->
        # Simple binary body
        Logger.debug("[#{method} #{path}] Body is binary: #{byte_size(body)} bytes")

        case chunk(conn, body) do
          {:ok, conn} -> conn
          {:error, :closed} -> conn
        end

      _ ->
        # For streaming, we need to receive messages
        Logger.debug("[#{method} #{path}] Body type requires message streaming")

        stream_chunks(conn)
    end
  end

  defp stream_chunks(conn) do
    method = Process.get(:proxy_method, "UNKNOWN")
    path = Process.get(:proxy_path, "UNKNOWN")

    receive do
      # Finch/Req format: {pool_ref, :data, data}
      {_pool_ref, {:data, data}} ->
        Logger.debug(
          "[#{method} #{path}] Received chunk: #{byte_size(data)} bytes - #{inspect(data, limit: 200)}"
        )

        case chunk(conn, data) do
          {:ok, conn} ->
            stream_chunks(conn)

          {:error, :closed} ->
            Logger.debug("[#{method} #{path}] Client closed connection")

            conn
        end

      # Finch/Req format: {pool_ref, :done}
      {_pool_ref, :done} ->
        Logger.debug("[#{method} #{path}] Stream completed")

        conn

      # Alternative format
      {:data, data} ->
        Logger.debug(
          "[#{method} #{path}] Received chunk (alt format): #{byte_size(data)} bytes - #{inspect(data, limit: 200)}"
        )

        case chunk(conn, data) do
          {:ok, conn} ->
            stream_chunks(conn)

          {:error, :closed} ->
            Logger.debug("[#{method} #{path}] Client closed connection")

            conn
        end

      {:done, _metadata} ->
        Logger.debug("[#{method} #{path}] Stream completed (alt format)")

        conn

      # Ignore connection cleanup messages
      {:EXIT, _pid, :normal} ->
        stream_chunks(conn)

      {:plug_conn, :sent} ->
        stream_chunks(conn)

      other ->
        Logger.debug("[#{method} #{path}] Ignoring stream message: #{inspect(other)}")

        stream_chunks(conn)
    after
      60_000 ->
        Logger.warning("[#{method} #{path}] Stream timeout after 60s of inactivity")

        conn
    end
  end

  defp parse_host_info(host) do
    case String.split(host, ".") do
      [subdomain | _] ->
        case String.split(subdomain, "--") do
          [username, repo] -> {username, repo}
          _ -> {"unknown", "unknown"}
        end

      _ ->
        {"unknown", "unknown"}
    end
  end
end
