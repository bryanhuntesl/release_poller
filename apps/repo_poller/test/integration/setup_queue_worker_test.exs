defmodule RepoPoller.SetupQueueWorkerTest do
  use ExUnit.Case, async: true

  alias RepoPoller.SetupQueueWorker

  @moduletag :integration
  @queue "test.queue"

  setup do
    caller = self()

    rabbitmq_config = [
      channels: 1,
      port: String.to_integer(System.get_env("POLLER_RMQ_PORT") || "5672"),
      queue: @queue,
      exchange: "my_exchange",
      caller: caller
    ]

    rabbitmq_conn_pool = [
      :rabbitmq_conn_pool,
      pool_id: :setup_queue_pool,
      name: {:local, :setup_queue_pool},
      worker_module: BugsBunny.Worker.RabbitConnection,
      size: 1,
      max_overflow: 0
    ]

    Application.put_env(:repo_poller, :rabbitmq_config, rabbitmq_config)
    Application.put_env(:repo_poller, :rabbitmq_conn_pool, rabbitmq_conn_pool)
    Application.put_env(:repo_poller, :database, Domain.Service.MockDatabase)

    start_supervised!(%{
      id: BugsBunny.PoolSupervisorTest,
      start:
        {BugsBunny.PoolSupervisor, :start_link,
         [
           [rabbitmq_config: rabbitmq_config, rabbitmq_conn_pool: rabbitmq_conn_pool],
           BugsBunny.PoolSupervisorTest
         ]},
      type: :supervisor
    })

    {:ok, pool_id: :setup_queue_pool}
  end

  test "declare queue on startup", %{pool_id: pool_id} do
    _worker_pid = start_supervised!(SetupQueueWorker)

    BugsBunny.with_channel(pool_id, fn {:ok, channel} ->
      assert :ok = AMQP.Basic.publish(channel, "my_exchange", "", "Hello, World!")
      assert {:ok, "Hello, World!", _meta} = AMQP.Basic.get(channel, @queue)
      assert {:ok, _} = AMQP.Queue.delete(channel, @queue)
    end)
  end
end
