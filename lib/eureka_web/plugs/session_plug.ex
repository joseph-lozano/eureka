defmodule EurekaWeb.Plugs.SessionPlug do
  @moduledoc """
  Ensures a unique session_id exists in the session for machine isolation.

  This session_id is used to isolate machines per browser session and repository.
  The same session_id + repository combination will reuse the same machine.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :session_id) do
      nil ->
        # Generate a new session ID
        session_id = generate_session_id()
        put_session(conn, :session_id, session_id)

      _session_id ->
        # Session ID already exists, nothing to do
        conn
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end
end
