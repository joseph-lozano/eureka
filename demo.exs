# Demo script for Eureka Fly.io API integration
# This script demonstrates creating a machine, managing sessions, and sending messages

Mix.install([])

# Load the application
Application.put_env(:eureka, :fly_api,
  api_key: System.get_env("FLY_API_KEY") || "demo-key",
  api_url: "https://api.machines.dev/v1",
  app_name: System.get_env("FLY_APP_NAME") || "eureka-demo"
)

# Step 1: Create a machine
{:ok, machine} = Eureka.Fly.create_machine()
machine_id = machine["id"]

# Step 2: List sessions (should be empty initially)
{:ok, sessions} = Eureka.Fly.list_sessions(machine_id)

# Step 3: Create a session
session_data = %{"title" => "Demo Session #{DateTime.utc_now()}"}
{:ok, session_id} = Eureka.Fly.create_session(machine_id, session_data)

# Step 4: List sessions again
{:ok, updated_sessions} = Eureka.Fly.list_sessions(machine_id)

# Step 5: Create a message
message_data = %{
  "parts" => [
    %{
      "type" => "text",
      "text" =>
        "Hello! This is a demo message sent to the Fly.io machine session."
    }
  ]
}

{:ok, message} = Eureka.Fly.create_message(machine_id, session_id, message_data)

# Step 6: List messages
{:ok, text_messages} = Eureka.Fly.list_messages(machine_id, session_id)
