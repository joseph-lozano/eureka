defmodule EurekaWeb.Plugs.AuthPlug do
  @moduledoc """
  Authentication plug for managing user sessions.
  """

  import Plug.Conn
  import Phoenix.Controller
  alias Eureka.Auth.UserSession

  def init(opts), do: opts

  def call(conn, _opts) do
    case UserSession.get_session_token(conn) do
      nil ->
        # No session token, assign nil current_user
        assign(conn, :current_user, nil)

      token ->
        case UserSession.verify_session_token(token) do
          {:ok, claims} ->
            # Valid token, assign current user
            assign(conn, :current_user, claims)

          {:error, reason} ->
            # Invalid token, clear cookie and assign nil
            require Logger
            Logger.error("Token verification failed: #{inspect(reason)}")

            conn
            |> UserSession.clear_session_cookie()
            |> assign(:current_user, nil)
        end
    end
  end

  @doc """
  Ensures the user is authenticated, otherwise redirects to login.
  """
  def require_auth(conn, opts \\ []) do
    if conn.assigns[:current_user] do
      conn
    else
      login_path = Keyword.get(opts, :login_path, "/auth/github")

      conn
      |> put_flash(:error, "Please log in to continue")
      |> redirect(to: login_path)
      |> halt()
    end
  end

  @doc """
  Ensures the user is not authenticated, otherwise redirects to home.
  """
  def require_guest(conn, _opts \\ []) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: "/")
      |> halt()
    else
      conn
    end
  end
end
