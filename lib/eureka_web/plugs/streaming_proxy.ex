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

    Logger.info("Proxying #{conn.method} #{conn.request_path} to #{url}")
    Logger.debug("Proxy headers: #{inspect(proxy_headers(conn))}")

    # Make the request with streaming enabled
    case Req.request(
           method: String.downcase(conn.method) |> String.to_atom(),
           url: url,
           headers: proxy_headers(conn),
           body: read_request_body(conn),
           into: :self,
           receive_timeout: :infinity,
           connect_options: [
             timeout: 60_000,
             transport_opts: [inet6: true]
           ]
         ) do
      {:ok, response} ->
        Logger.info("Received response: status=#{response.status}")
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
    case Plug.Conn.read_body(conn, []) do
      {:ok, body, _conn} -> body
      {:more, _partial, _conn} -> ""
      {:error, _reason} -> ""
    end
  end

  defp stream_response(conn, %{status: status, headers: headers, body: body}) do
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
        Enum.reduce_while(chunks, conn, fn chunk, conn ->
          case chunk(conn, chunk) do
            {:ok, conn} -> {:cont, conn}
            {:error, :closed} -> {:halt, conn}
          end
        end)

      body when is_binary(body) ->
        # Simple binary body
        case chunk(conn, body) do
          {:ok, conn} -> conn
          {:error, :closed} -> conn
        end

      _ ->
        # For streaming, we need to receive messages
        stream_chunks(conn)
    end
  end

  defp stream_chunks(conn) do
    receive do
      # Finch/Req format: {pool_ref, :data, data}
      {_pool_ref, {:data, data}} ->
        case chunk(conn, data) do
          {:ok, conn} ->
            stream_chunks(conn)

          {:error, :closed} ->
            conn
        end

      # Finch/Req format: {pool_ref, :done}
      {_pool_ref, :done} ->
        conn

      # Alternative format
      {:data, data} ->
        case chunk(conn, data) do
          {:ok, conn} ->
            stream_chunks(conn)

          {:error, :closed} ->
            conn
        end

      {:done, _metadata} ->
        conn

      # Ignore connection cleanup messages
      {:EXIT, _pid, :normal} ->
        stream_chunks(conn)

      {:plug_conn, :sent} ->
        stream_chunks(conn)

      other ->
        Logger.debug("Ignoring stream message: #{inspect(other)}")
        stream_chunks(conn)
    after
      60_000 ->
        Logger.warning("Stream timeout after 60s of inactivity")
        conn
    end
  end
end
