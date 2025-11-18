defmodule EurekaWeb.UserLiveAuth do
  @moduledoc """
  Authentication hook for LiveViews using on_mount.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  require Logger
  alias Eureka.Auth.UserSession

  def on_mount(:default, _params, session, socket) do
    Logger.debug("LiveView session contents: #{inspect(session)}")

    socket =
      assign_new(socket, :current_user, fn ->
        verify_user_token(session)
      end)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end

  defp verify_user_token(%{"user_token" => user_token}) do
    Logger.debug("Found user_token in session, verifying...")

    with {:ok, claims} <- UserSession.verify_session_token(user_token) do
      Logger.debug("Token verified successfully")
      claims
    else
      {:error, reason} ->
        Logger.debug("Token verification failed: #{inspect(reason)}")
        nil
    end
  end

  defp verify_user_token(_session) do
    Logger.debug("No user_token in session, redirecting")
    nil
  end
end
