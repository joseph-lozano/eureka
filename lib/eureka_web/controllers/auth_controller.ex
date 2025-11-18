defmodule EurekaWeb.AuthController do
  @moduledoc """
  Handles GitHub OAuth authentication flow.
  """

  use EurekaWeb, :controller

  alias Eureka.Auth.UserSession
  require Logger

  def new(conn, _params) do
    github_config = Application.get_env(:eureka, :github_oauth)
    client_id = github_config[:client_id]
    callback_url = github_config[:callback_url]

    if is_nil(client_id) do
      conn
      |> put_flash(:error, "GitHub OAuth not configured")
      |> redirect(to: "/")
    else
      state = generate_state()

      conn = put_session(conn, :oauth_state, state)

      auth_url = build_auth_url(client_id, callback_url, state)

      redirect(conn, external: auth_url)
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    # Verify state parameter
    case get_session(conn, :oauth_state) do
      ^state ->
        handle_oauth_callback(conn, code)

      _ ->
        conn
        |> put_flash(:error, "Invalid OAuth state")
        |> redirect(to: "/")
    end
  end

  def callback(conn, %{"error" => error}) do
    Logger.error("OAuth error: #{error}")

    conn
    |> put_flash(:error, "Authentication failed")
    |> redirect(to: "/")
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Invalid OAuth callback")
    |> redirect(to: "/")
  end

  def delete(conn, _params) do
    conn
    |> UserSession.clear_session_cookie()
    |> clear_session()
    |> put_flash(:info, "Logged out successfully")
    |> redirect(to: "/")
  end

  # Private helpers

  defp handle_oauth_callback(conn, code) do
    case exchange_code_for_token(code) do
      {:ok, access_token} ->
        case fetch_user_info(access_token) do
          {:ok, user_info} ->
            create_user_session(conn, user_info)

          {:error, reason} ->
            Logger.error("Failed to fetch user info: #{reason}")

            conn
            |> put_flash(:error, "Failed to fetch user information")
            |> redirect(to: "/")
        end

      {:error, reason} ->
        Logger.error("Failed to exchange code for token: #{reason}")

        conn
        |> put_flash(:error, "Authentication failed")
        |> redirect(to: "/")
    end
  end

  defp exchange_code_for_token(code) do
    github_config = Application.get_env(:eureka, :github_oauth)
    client_id = github_config[:client_id]
    client_secret = github_config[:client_secret]
    callback_url = github_config[:callback_url]

    url = "https://github.com/login/oauth/access_token"

    params = %{
      client_id: client_id,
      client_secret: client_secret,
      code: code,
      redirect_uri: callback_url
    }

    headers = [
      {"Accept", "application/json"},
      {"User-Agent", "Eureka-App"}
    ]

    case Req.post(url, json: params, headers: headers) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Token exchange failed: #{status}, #{inspect(body)}")
        {:error, :token_exchange_failed}

      {:error, reason} ->
        Logger.error("Token exchange request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  defp fetch_user_info(access_token) do
    with {:ok, user_data} <- UserSession.fetch_github_user(access_token),
         {:ok, email} <- UserSession.fetch_github_emails(access_token) do
      user_info = %{
        "id" => user_data["id"],
        "login" => user_data["login"],
        "email" => email,
        "name" => user_data["name"],
        "avatar_url" => user_data["avatar_url"]
      }

      {:ok, user_info}
    else
      error -> error
    end
  end

  defp create_user_session(conn, user_info) do
    if user_allowed?(user_info["login"]) do
      case UserSession.create_session_token(user_info) do
        {:ok, token, _user} ->
          conn
          |> UserSession.set_session_cookie(token)
          |> clear_session()
          |> put_flash(:info, "Successfully logged in!")
          |> redirect(to: "/")

        {:error, reason} ->
          Logger.error("Failed to create session token: #{reason}")

          conn
          |> put_flash(:error, "Failed to create session")
          |> redirect(to: "/")
      end
    else
      Logger.warning("User #{user_info["login"]} not in allowed users list")

      conn
      |> put_flash(:error, "Access denied")
      |> redirect(to: "/")
    end
  end

  defp generate_state do
    :crypto.strong_rand_bytes(32) |> Base.encode64()
  end

  defp user_allowed?(username) do
    allowed_users = Application.get_env(:eureka, :allowed_users)[:users] || []

    username in allowed_users
  end

  defp build_auth_url(client_id, callback_url, state) do
    params = %{
      client_id: client_id,
      redirect_uri: callback_url,
      scope: "user:email",
      state: state
    }

    query = URI.encode_query(params)
    "https://github.com/login/oauth/authorize?#{query}"
  end
end
