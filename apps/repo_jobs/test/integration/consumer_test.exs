defmodule RepoJobs.Integration.ConsumerTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  import Mox

  alias BugsBunny.RabbitMQ
  alias BugsBunny.Worker.RabbitConnection
  alias RepoJobs.Consumer
  alias AMQP.{Connection, Channel, Queue}
  alias Domain.Jobs.NewReleaseJob
  alias Domain.Serializers.NewReleaseJobSerializer
  alias Domain.Repos.Repo
  alias Domain.Tags.Tag
  alias Domain.Tasks.Task

  @moduletag :integration
  @queue "test.consumer.queue"

  setup do
    # setup test queue in RabbitMQ
    {:ok, conn} = Connection.open()
    {:ok, channel} = Channel.open(conn)
    {:ok, %{queue: queue}} = Queue.declare(channel, @queue)

    on_exit(fn ->
      {:ok, _} = Queue.delete(channel, queue)
      :ok = Connection.close(conn)
    end)

    {:ok, channel: channel}
  end

  setup do
    n = :rand.uniform(100)
    pool_id = String.to_atom("test_pool#{n}")

    rabbitmq_config = [
      channels: 1,
      queue: @queue,
      exchange: "",
      client: RabbitMQ
    ]

    rabbitmq_conn_pool = [
      :rabbitmq_conn_pool,
      pool_id: pool_id,
      name: {:local, pool_id},
      worker_module: RabbitConnection,
      size: 1,
      max_overflow: 0
    ]

    Application.put_env(:repo_jobs, :rabbitmq_config, rabbitmq_config)

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

    {:ok, pool_id: pool_id}
  end

  test "handles channel crashes", %{pool_id: pool_id} do
    log =
      capture_log(fn ->
        pid = start_supervised!({Consumer, pool_id})
        assert %{channel: channel} = Consumer.state(pid)
        :erlang.trace(pid, true, [:receive])
        %{pid: channel_pid} = channel
        :ok = Channel.close(channel)
        # channel is down
        assert_receive {:trace, ^pid, :receive, {:DOWN, _ref, :process, ^channel_pid, :normal}}
        # attempt to reconnect
        assert_receive {:trace, ^pid, :receive, :connect}
        # consuming messages again
        assert_receive {:trace, ^pid, :receive,
                        {:basic_consume_ok, %{consumer_tag: _consumer_tag}}}

        assert %{channel: channel2} = Consumer.state(pid)
        refute channel == channel2
      end)

    assert log =~ "[error] [consumer] channel down reason: :normal"
    assert log =~ "[error] [Rabbit] channel lost, attempting to reconnect reason: :normal"
  end

  test "consumes messaged published to the queue", %{channel: channel, pool_id: pool_id} do
    start_supervised!({Consumer, {self(), pool_id}})

    payload =
      "{\"repo\":{\"owner\":\"elixir-lang\",\"name\":\"elixir\"},\"new_tag\":{\"zipball_url\":\"https://api.github.com/repos/elixir-lang/elixir/zipball/v1.7.2\",\"tarball_url\":\"https://api.github.com/repos/elixir-lang/elixir/tarball/v1.7.2\",\"node_id\":\"MDM6UmVmMTIzNDcxNDp2MS43LjI=\",\"name\":\"v1.7.2\",\"commit\":{\"url\":\"https://api.github.com/repos/elixir-lang/elixir/commits/2b338092b6da5cd5101072dfdd627cfbb49e4736\",\"sha\":\"2b338092b6da5cd5101072dfdd627cfbb49e4736\"}}}"

    :ok = RabbitMQ.publish(channel, "", @queue, payload)
    assert_receive {:new_release_job, job}, 1000

    assert job == %NewReleaseJob{
             new_tag: %Tag{
               commit: %{
                 sha: "2b338092b6da5cd5101072dfdd627cfbb49e4736",
                 url:
                   "https://api.github.com/repos/elixir-lang/elixir/commits/2b338092b6da5cd5101072dfdd627cfbb49e4736"
               },
               name: "v1.7.2",
               node_id: "MDM6UmVmMTIzNDcxNDp2MS43LjI=",
               tarball_url: "https://api.github.com/repos/elixir-lang/elixir/tarball/v1.7.2",
               zipball_url: "https://api.github.com/repos/elixir-lang/elixir/zipball/v1.7.2"
             },
             repo: %Repo{name: "elixir", owner: "elixir-lang", tags: []}
           }
  end

  describe "process jobs" do
    # Make sure mocks are verified when the test exits
    setup :verify_on_exit!
    # Allow any process to consume mocks and stubs defined in tests.
    setup :set_mox_global

    setup do
      tag = %Tag{
        commit: %{
          sha: "",
          url: ""
        },
        name: "v1.7.2",
        node_id: "",
        tarball_url: "tarball/v1.7.2",
        zipball_url: "zipball/v1.7.2"
      }

      repo =
        Repo.new("https://github.com/elixir-lang/elixir")
        |> Repo.add_tags([tag])

      {:ok, repo: repo}
    end

    test "successfully process one job's task", %{
      repo: repo,
      channel: channel,
      pool_id: pool_id
    } do
      start_supervised!({Consumer, {self(), pool_id}})

      %{tags: [tag]} = repo

      task1 = %Task{
        url: "https://github.com/f@k31/fake",
        runner: Domain.TaskMockRunner,
        source: Domain.TaskMockSource
      }

      task2 = %Task{
        url: "https://github.com/f@k32/fake",
        runner: Domain.TaskMockRunner,
        source: Domain.TaskMockSource
      }

      Domain.TaskMockSource
      |> expect(:fetch, 2, fn task, _tmp_dir -> {:ok, task} end)

      Domain.TaskMockRunner
      |> expect(:exec, 2, fn _task, _env -> :ok end)

      payload =
        repo
        |> Repo.set_tasks([task1, task2])
        |> NewReleaseJob.new(tag)
        |> NewReleaseJobSerializer.serialize!()

      :ok = RabbitMQ.publish(channel, "", @queue, payload)
      assert_receive {:new_release_job, _}, 1000
      assert_receive {:ack, task_results}, 1000
      assert [{:ok, ^task1}, {:ok, ^task2}] = task_results
    end

    test "failed to process job's tasks", %{
      repo: repo,
      channel: channel,
      pool_id: pool_id
    } do
      start_supervised!({Consumer, {self(), pool_id}})

      %{tags: [tag]} = repo

      task1 = %Task{
        url: "https://github.com/f@k31/fake",
        runner: Domain.TaskMockRunner,
        source: Domain.TaskMockSource
      }

      task2 = %Task{
        url: "https://github.com/f@k32/fake",
        runner: Domain.TaskMockRunner,
        source: Domain.TaskMockSource
      }

      Domain.TaskMockSource
      |> expect(:fetch, 2, fn task, _tmp_dir -> {:ok, task} end)

      Domain.TaskMockRunner
      |> expect(:exec, 2, fn
        ^task1, _env -> {:error, :eaccess}
        ^task2, _env -> :ok
      end)

      payload =
        repo
        |> Repo.set_tasks([task1, task2])
        |> NewReleaseJob.new(tag)
        |> NewReleaseJobSerializer.serialize!()

      log =
        capture_log(fn ->
          :ok = RabbitMQ.publish(channel, "", @queue, payload)
          assert_receive {:new_release_job, _}, 1000
          assert_receive {:ack, task_results}, 1000
          assert [{:error, ^task1}, {:ok, ^task2}] = task_results
        end)

      assert log =~
               "[error] error running task https://github.com/f@k31/fake for elixir-lang/elixir#v1.7.2 reason: :eaccess"
    end

    test "failed to process all job's tasks", %{
      repo: repo,
      channel: channel,
      pool_id: pool_id
    } do
      start_supervised!({Consumer, {self(), pool_id}})

      %{tags: [tag]} = repo

      task1 = %Task{
        url: "https://github.com/f@k31/fake",
        runner: Domain.TaskMockRunner,
        source: Domain.TaskMockSource
      }

      task2 = %Task{
        url: "https://github.com/f@k32/fake",
        runner: Domain.TaskMockRunner,
        source: Domain.TaskMockSource
      }

      Domain.TaskMockSource
      |> expect(:fetch, 2, fn task, _tmp_dir -> {:ok, task} end)

      Domain.TaskMockRunner
      |> expect(:exec, 2, fn _task, _env -> {:error, :eaccess} end)

      payload =
        repo
        |> Repo.set_tasks([task1, task2])
        |> NewReleaseJob.new(tag)
        |> NewReleaseJobSerializer.serialize!()

      log =
        capture_log(fn ->
          :ok = RabbitMQ.publish(channel, "", @queue, payload)
          assert_receive {:new_release_job, _}, 1000
          assert_receive {:reject, task_results}, 1000
          assert [{:error, ^task1}, {:error, ^task2}] = task_results
        end)

      assert log =~
               "[error] error running task https://github.com/f@k31/fake for elixir-lang/elixir#v1.7.2 reason: :eaccess"

      assert log =~
               "[error] error running task https://github.com/f@k32/fake for elixir-lang/elixir#v1.7.2 reason: :eaccess"
    end
  end
end