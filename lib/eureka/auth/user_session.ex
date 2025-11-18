defmodule Eureka.Auth.UserSession do
  @moduledoc """
  Manages user session tokens and GitHub OAuth integration.
  """

  alias EurekaWeb.Endpoint
  require Logger

  defp session_secret, do: Application.get_env(:eureka, :jwt)[:session_secret]
  defp token_expiry, do: Application.get_env(:eureka, :jwt)[:token_expiry] || 20 * 60 * 60

  defp token_signer, do: Joken.Signer.create("HS256", session_secret())

  @doc """
  Creates a new JWT session token for a GitHub user.
  """
  def create_session_token(%{
        "id" => github_id,
        "login" => login,
        "email" => email,
        "name" => name,
        "avatar_url" => avatar_url
      }) do
    current_time = Joken.current_time()
    exp_time = current_time + token_expiry()

    extra_claims = %{
      "github_id" => github_id,
      "login" => login,
      "email" => email,
      "name" => name,
      "avatar_url" => avatar_url,
      "iat" => current_time,
      "exp" => exp_time,
      "type" => "session"
    }

    extra_claims
    |> Joken.encode_and_sign(token_signer())
  end

  @doc """
  Verifies and validates a JWT session token.
  """
  def verify_session_token(token) do
    token
    |> Joken.verify(token_signer())
    |> case do
      {:ok, claims} -> validate_claims(claims)
      error -> error
    end
  end

  @doc """
  Fetches GitHub user information using the access token.
  """
  def fetch_github_user(access_token) do
    url = "https://api.github.com/user"

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Accept", "application/vnd.github.v3+json"},
      {"User-Agent", "Eureka-App"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: user_data}} ->
        {:ok, user_data}

      {:ok, %{status: status}} ->
        Logger.error("GitHub API error: #{status}")
        {:error, :github_api_error}

      {:error, reason} ->
        Logger.error("GitHub request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  @doc """
  Fetches GitHub user emails using the access token.
  """
  def fetch_github_emails(access_token) do
    url = "https://api.github.com/user/emails"

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Accept", "application/vnd.github.v3+json"},
      {"User-Agent", "Eureka-App"}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: emails}} ->
        primary_email = Enum.find(emails, & &1["primary"])
        email = primary_email["email"] || List.first(emails)["email"]
        {:ok, email}

      {:ok, %{status: status}} ->
        Logger.error("GitHub emails API error: #{status}")
        {:error, :github_api_error}

      {:error, reason} ->
        Logger.error("GitHub emails request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  @doc """
  Sets the session token in a secure cookie.
  """
  def set_session_cookie(conn, token) do
    conn
    |> Plug.Conn.put_resp_cookie(
      "eureka_session",
      token,
      max_age: token_expiry(),
      http_only: true,
      secure: Endpoint.config(:force_ssl, false),
      same_site: "Lax"
    )
  end

  @doc """
  Clears the session cookie.
  """
  def clear_session_cookie(conn) do
    conn
    |> Plug.Conn.delete_resp_cookie("eureka_session",
      http_only: true,
      secure: Endpoint.config(:force_ssl, false),
      same_site: "Lax"
    )
  end

  @doc """
  Gets session token from request cookies.
  """
  def get_session_token(conn) do
    token = conn.cookies["eureka_session"]
    require Logger
    Logger.debug("Session token: #{inspect(token)}")
    Logger.debug("All cookies: #{inspect(conn.cookies)}")
    token
  end

  # Private helpers

  defp validate_claims(%{"type" => "session"} = claims) do
    {:ok, claims}
  end

  defp validate_claims(_claims) do
    {:error, :invalid_token_type}
  end
end
