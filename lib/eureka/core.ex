defmodule Eureka.Core do
  use Ash.Domain

  resources do
    resource Eureka.Core.Repository
  end
end
