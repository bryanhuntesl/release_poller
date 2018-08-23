  # TODOL: change this fake adapter to not depend on RabbitMQ
  # based on this: http://tech.adroll.com/blog/dev/2018/03/28/elixir-stubs-for-tests.html
  defmodule BugsBunny.FakeRabbitMQ do
    @behaviour BugsBunny.Clients.Adapter
    use AMQP

    @impl true
    def publish(_channel, _exchange, _routing_key, _payload, _options \\ []) do
      :ok
    end

    @impl true
    def consume(_channel, _queue, _consumer_pid \\ nil, _options \\ []) do
      {:ok, "tag"}
    end

    @impl true
    def open_connection(config) do
      if Keyword.get(config, :queue) == "error.queue" do
        {:error, :invalid}
      else
        # Connection.open(config)
        {:ok, %Connection{pid: self()}}
      end
    end

    @impl true
    def open_channel(conn) do
      # Channel.open(conn)
      {:ok, %Channel{conn: conn, pid: self()}}
    end

    @impl true
    def close_connection(_conn) do
      #  Connection.close(conn)
      :ok
    end
  end
