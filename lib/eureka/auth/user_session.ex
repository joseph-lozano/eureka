defmodule Eureka.Auth.UserSession do
  @moduledoc """
  Manages user session tokens and GitHub OAuth integration.
  """

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
    # Get cookie domain from endpoint config, or determine from host
    cookie_domain = get_cookie_domain(conn)

    Logger.info(
      "Setting eureka_session cookie with domain: #{inspect(cookie_domain)} for host: #{conn.host}"
    )

    # In production, always use secure cookies
    secure = conn.scheme == :https

    conn
    |> Plug.Conn.put_resp_cookie(
      "eureka_session",
      token,
      max_age: token_expiry(),
      http_only: true,
      secure: secure,
      same_site: "Lax",
      domain: cookie_domain
    )
  end

  @doc """
  Clears the session cookie.
  """
  def clear_session_cookie(conn) do
    cookie_domain = get_cookie_domain(conn)
    secure = conn.scheme == :https

    conn
    |> Plug.Conn.delete_resp_cookie("eureka_session",
      http_only: true,
      secure: secure,
      same_site: "Lax",
      domain: cookie_domain
    )
  end

  # Determines the cookie domain to use based on the host
  # In development: .eureka.local (to share with subdomains)
  # In production: .eureka.dev or configured domain
  defp get_cookie_domain(conn) do
    host = conn.host

    cond do
      # Development: eureka.local and subdomains
      # Note: browsers don't allow wildcard cookies on .localhost
      String.ends_with?(host, ".eureka.local") or host == "eureka.local" ->
        ".eureka.local"

      # Legacy localhost support (won't work with subdomains)
      String.ends_with?(host, ".localhost") or host == "localhost" ->
        nil

      # Production: eureka.dev and subdomains
      String.ends_with?(host, ".eureka.dev") or host == "eureka.dev" ->
        ".eureka.dev"

      # Production: extract base domain from subdomain
      String.contains?(host, "--") ->
        # Extract base domain from workspace subdomain
        # e.g., "sst--opencode.eureka.dev" -> ".eureka.dev"
        case String.split(host, ".") do
          [_subdomain | rest] when length(rest) >= 2 ->
            "." <> Enum.join(rest, ".")

          _ ->
            nil
        end

      # Default: no domain restriction
      true ->
        nil
    end
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
