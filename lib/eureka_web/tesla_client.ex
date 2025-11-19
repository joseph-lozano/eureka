defmodule EurekaWeb.TeslaClient do
  @moduledoc """
  Tesla HTTP client configured for proxying to Fly.io internal machines.
  
  Uses Finch adapter with IPv6 support for connecting to .internal domains.
  """

  def client do
    middleware = [
      {Tesla.Middleware.Timeout, timeout: :infinity}
    ]

    adapter =
      {Tesla.Adapter.Finch,
       name: Eureka.Finch,
       receive_timeout: :infinity,
       pool_timeout: :infinity}

    Tesla.client(middleware, adapter)
  end
end
