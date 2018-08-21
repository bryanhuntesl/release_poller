use Mix.Config

config :repo_jobs, :rabbitmq_config,
  host: "192.168.1.10",
  port: 5672,
  channels: 1,
  queue: "new_releases.queue",
  exchange: ""

config :repo_jobs, :rabbitmq_conn_pool,
  pool_id: :connection_pool,
  name: {:local, :connection_pool},
  worker_module: BugsBunny.Worker.RabbitConnection,
  size: 1,
  max_overflow: 0

config :repo_jobs, :consumers, 1
