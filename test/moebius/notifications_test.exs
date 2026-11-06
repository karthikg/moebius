defmodule Moebius.NotificationsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Moebius.Notifications

  defmodule NotifyDb do
    @moduledoc false
    use Moebius.Database
  end

  defmodule DownDb do
    @moduledoc false
    use Moebius.Database
  end

  # short enough that reconnect and heartbeat tests finish fast
  @fast [heartbeat: 50, timeout: 200, backoff_min: 10, backoff_max: 50]

  setup do
    start_supervised!(
      {NotifyDb, Moebius.get_connection() ++ [pool_size: 2, notifications: @fast]}
    )

    # the listener connects in the background; wait for it, so listen/1 returns {:ok, ref}
    assert eventually(fn -> :sys.get_state(Notifications.name(NotifyDb)).status == :ready end)
    :ok
  end

  describe "listen/1 and notify/2" do
    test "delivers a notification to the listener" do
      assert {:ok, ref} = NotifyDb.listen("orders")

      assert :ok = NotifyDb.notify("orders", "order 42 paid")

      assert_receive {:moebius_notification, ^ref, "orders", "order 42 paid"}, 1_000
    end

    test "an empty payload arrives as an empty string" do
      {:ok, ref} = NotifyDb.listen(:pings)

      assert :ok = NotifyDb.notify(:pings)

      assert_receive {:moebius_notification, ^ref, "pings", ""}, 1_000
    end

    test "a map payload is sent as JSON" do
      {:ok, ref} = NotifyDb.listen("orders")

      :ok = NotifyDb.notify("orders", %{id: 42, status: "paid"})

      assert_receive {:moebius_notification, ^ref, "orders", json}, 1_000
      assert Jason.decode!(json) == %{"id" => 42, "status" => "paid"}
    end

    test "notifications from any connection arrive, including raw pg_notify" do
      {:ok, ref} = NotifyDb.listen("orders")

      assert {:ok, _} = TestDb.run("select pg_notify('orders', 'from TestDb')")

      assert_receive {:moebius_notification, ^ref, "orders", "from TestDb"}, 1_000
    end

    test "a channel name keeps its case, spaces and quotes" do
      channel = ~s(Order "Items" 2026)
      {:ok, ref} = NotifyDb.listen(channel)

      :ok = NotifyDb.notify(channel, "x")
      :ok = NotifyDb.notify(String.downcase(channel), "other channel")

      assert_receive {:moebius_notification, ^ref, ^channel, "x"}, 1_000
      refute_receive {:moebius_notification, ^ref, _, "other channel"}, 100
    end

    test "a listener only receives its own channels" do
      {:ok, ref} = NotifyDb.listen("a")

      :ok = NotifyDb.notify("b", "for b")
      :ok = NotifyDb.notify("a", "for a")

      assert_receive {:moebius_notification, ^ref, "a", "for a"}, 1_000
      refute_received {:moebius_notification, _, "b", _}
    end

    test "every listener on a channel receives each notification once" do
      {:ok, mine} = NotifyDb.listen("orders")
      other = listen_from_task("orders")

      :ok = NotifyDb.notify("orders", "both")

      assert_receive {:moebius_notification, ^mine, "orders", "both"}, 1_000
      assert_receive {:task_got, ^other, "both"}, 1_000
      refute_receive {:moebius_notification, ^mine, "orders", "both"}, 100
    end

    test "listening twice on one channel gives two subscriptions" do
      {:ok, first} = NotifyDb.listen("orders")
      {:ok, second} = NotifyDb.listen("orders")

      :ok = NotifyDb.notify("orders", "twice")

      assert first != second
      assert_receive {:moebius_notification, ^first, "orders", "twice"}, 1_000
      assert_receive {:moebius_notification, ^second, "orders", "twice"}, 1_000
    end
  end

  describe "transactions" do
    test "a notification inside a transaction arrives only after commit" do
      {:ok, ref} = NotifyDb.listen("orders")
      test = self()

      :done =
        NotifyDb.transaction(fn _tx ->
          :ok = NotifyDb.notify("orders", "committed")
          send(test, :notified_inside)
          refute_receive {:moebius_notification, _, _, _}, 100
          :done
        end)

      assert_received :notified_inside
      assert_receive {:moebius_notification, ^ref, "orders", "committed"}, 1_000
    end

    test "a rolled-back transaction delivers nothing" do
      {:ok, ref} = NotifyDb.listen("orders")

      assert {:error, :cancelled} =
               NotifyDb.transaction(fn _tx ->
                 :ok = NotifyDb.notify("orders", "never")
                 NotifyDb.rollback(:cancelled)
               end)

      :ok = NotifyDb.notify("orders", "after")
      assert_receive {:moebius_notification, ^ref, "orders", "after"}, 1_000
      refute_received {:moebius_notification, ^ref, "orders", "never"}
    end

    test "notifications from one transaction arrive in the order they were sent" do
      {:ok, ref} = NotifyDb.listen("orders")

      [:ok, :ok, :ok, :ok, :ok] =
        NotifyDb.transaction(fn _tx ->
          for n <- 1..5, do: :ok = NotifyDb.notify("orders", "#{n}")
        end)

      for n <- 1..5 do
        payload = "#{n}"
        assert_receive {:moebius_notification, ^ref, "orders", ^payload}, 1_000
      end
    end
  end

  describe "unlisten/1 and listeners leaving" do
    test "after unlisten the subscription gets nothing more" do
      {:ok, ref} = NotifyDb.listen("orders")

      assert :ok = NotifyDb.unlisten(ref)
      :ok = NotifyDb.notify("orders", "too late")

      refute_receive {:moebius_notification, ^ref, _, _}, 200
    end

    test "unlisten leaves the other listeners on the channel alone" do
      {:ok, gone} = NotifyDb.listen("orders")
      {:ok, kept} = NotifyDb.listen("orders")

      :ok = NotifyDb.unlisten(gone)
      :ok = NotifyDb.notify("orders", "still here")

      assert_receive {:moebius_notification, ^kept, "orders", "still here"}, 1_000
      refute_received {:moebius_notification, ^gone, _, _}
    end

    test "the last listener leaving sends UNLISTEN for the channel" do
      {:ok, ref} = NotifyDb.listen("orders")
      assert listening() == MapSet.new(["orders"])

      :ok = NotifyDb.unlisten(ref)

      assert eventually(fn -> listening() == MapSet.new() end)
    end

    test "a listener that exits is removed and its channel unlistened" do
      task = listen_from_task("orders")
      assert listening() == MapSet.new(["orders"])

      send(task, :stop)

      assert eventually(fn -> listening() == MapSet.new() and subs() == %{} end)
    end

    test "unlisten with an unknown ref is a no-op" do
      assert :ok = NotifyDb.unlisten(make_ref())
    end
  end

  describe "reconnecting" do
    test "a terminated connection reconnects and listens again" do
      {:ok, ref} = NotifyDb.listen("orders")

      log =
        capture_log(fn ->
          assert {:ok, [%{terminated: true}]} = terminate_listener()

          assert_receive {:moebius_listener, ^ref, :disconnected}, 1_000
          assert_receive {:moebius_listener, ^ref, :connected}, 2_000
        end)

      assert log =~ "lost the connection"
      :ok = NotifyDb.notify("orders", "after reconnect")
      assert_receive {:moebius_notification, ^ref, "orders", "after reconnect"}, 1_000
    end

    test "the heartbeat replaces a connection that stops answering" do
      {:ok, ref} = NotifyDb.listen("orders")
      conn = :sys.get_state(Notifications.name(NotifyDb)).conn

      log =
        capture_log(fn ->
          # a suspended process reads nothing, like a server behind a dead network
          :sys.suspend(conn)

          assert_receive {:moebius_listener, ^ref, :disconnected}, 2_000
          assert_receive {:moebius_listener, ^ref, :connected}, 2_000
        end)

      assert log =~ "no answer from the server"
      refute Process.alive?(conn)
      :ok = NotifyDb.notify("orders", "on the new connection")
      assert_receive {:moebius_notification, ^ref, "orders", "on the new connection"}, 1_000
    end

    test "the pool keeps working while the listener reconnects" do
      {:ok, _ref} = NotifyDb.listen("orders")

      capture_log(fn ->
        {:ok, _} = terminate_listener()

        assert {:ok, [%{n: 1}]} = NotifyDb.run("select 1 as n")
      end)
    end

    test "a database that is down: listen returns :eventually and nothing crashes" do
      log =
        capture_log(fn ->
          start_supervised!(
            {DownDb,
             [
               hostname: "localhost",
               port: 1,
               database: "nowhere",
               pool_size: 1,
               pool_min: 0,
               notifications: @fast
             ]}
          )

          server = Process.whereis(Notifications.name(DownDb))

          assert {:eventually, ref} = DownDb.listen("orders")
          assert is_reference(ref)
          assert eventually(fn -> :sys.get_state(server).status == :backoff end)
          assert Process.alive?(server)
        end)

      assert log =~ "can't connect"
    end
  end

  describe "arguments" do
    test "listen returns an error when notifications aren't enabled" do
      assert {:error, "notifications aren't running for TestDb" <> _} = TestDb.listen("orders")
    end

    test "notify works without notifications enabled" do
      assert :ok = TestDb.notify("orders", "fine")
    end

    test "bad channel names raise before anything is sent" do
      for bad <- ["", String.duplicate("x", 64), nil, 42, "nul\0byte"] do
        assert_raise ArgumentError, fn -> NotifyDb.listen(bad) end
        assert_raise ArgumentError, fn -> NotifyDb.notify(bad, "x") end
      end
    end

    test "a 63-byte channel is the longest allowed" do
      channel = String.duplicate("x", 63)
      {:ok, ref} = NotifyDb.listen(channel)

      :ok = NotifyDb.notify(channel, "max")

      assert_receive {:moebius_notification, ^ref, ^channel, "max"}, 1_000
    end

    test "a payload that isn't a string, map or list raises" do
      assert_raise ArgumentError, ~r/payload must be/, fn -> NotifyDb.notify("orders", 42) end
    end

    test "a payload over Postgres's limit is an error, not a crash" do
      assert {:error, "payload string too long"} =
               NotifyDb.notify("orders", String.duplicate("x", 8_000))

      assert {:ok, [%{n: 1}]} = NotifyDb.run("select 1 as n")
    end

    test "unlisten needs a ref" do
      assert_raise ArgumentError, ~r/expects the ref/, fn -> NotifyDb.unlisten("orders") end
    end

    test "invalid options raise at start" do
      for bad <- [[heartbeat: 0], [bogus: 1], [backoff_min: 100, backoff_max: 10], :yes] do
        assert_raise ArgumentError, fn ->
          Notifications.start_link(DownDb, notifications: bad)
        end
      end
    end
  end

  describe "notify_command/2" do
    test "sends channel and payload as parameters" do
      assert Notifications.notify_command(:orders, "x'); drop table users; --") ==
               {"select pg_notify($1, $2)", ["orders", "x'); drop table users; --"]}
    end

    test "encodes a list payload as JSON" do
      assert Notifications.notify_command("orders", [1, 2]) ==
               {"select pg_notify($1, $2)", ["orders", "[1,2]"]}
    end
  end

  # ---- helpers ----

  # A separate process that listens and reports what it gets, until told to stop.
  defp listen_from_task(channel) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, ref} = NotifyDb.listen(channel)
        send(test, {:listening, self()})
        relay(test)
        ref
      end)

    assert_receive {:listening, ^pid}, 1_000
    pid
  end

  defp relay(test) do
    receive do
      {:moebius_notification, _ref, _channel, payload} ->
        send(test, {:task_got, self(), payload})
        relay(test)

      :stop ->
        :ok
    end
  end

  # ends the listening connection from the server side, as a restart or failover would
  defp terminate_listener do
    conn = :sys.get_state(Notifications.name(NotifyDb)).conn
    backend = :epgsql.get_backend_pid(conn)
    TestDb.run("select pg_terminate_backend($1) as terminated", [backend])
  end

  defp listening, do: :sys.get_state(Notifications.name(NotifyDb)).listening
  defp subs, do: :sys.get_state(Notifications.name(NotifyDb)).subs

  # polls a condition for up to a second instead of sleeping a fixed time
  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> receive(after: (20 -> eventually(fun, tries - 1)))
    end
  end
end
