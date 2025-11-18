defmodule Eureka.Core.Repository do
  use Ash.Resource,
    domain: Eureka.Core

  actions do
    read :read do
      primary? true
    end

    create :create do
      primary? true
      accept [:username, :name, :user_id]
      upsert? true
      upsert_identity :unique_user_repo_name
      change Eureka.Changes.CreateFlyMachineAndWriteFile
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :username, :string, public?: true
    attribute :name, :string, public?: true
    attribute :user_id, :string, public?: true
    attribute :machine_id, :string, public?: true
  end

  identities do
    identity :unique_user_repo_name, [:user_id, :username, :name]
  end
end
