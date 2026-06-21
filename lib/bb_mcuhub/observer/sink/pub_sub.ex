defmodule BBMcuhub.Observer.Sink.PubSub do
  @moduledoc """
  The PubSub-republish sink — re-publishes a sampled value on the observer's
  **own** slow topic (ADR-0004).

  The motivating problem (ADR-0004 · Consequences): the control loop floods the
  broad `[:sensor]` / `[:actuator]` prefixes a dashboard subscribes to (100 Hz pose
  + the command cascade), lagging the dashboard. The fix is NOT to slow the loop but
  to feed the dashboard from an observer at the dashboard's own rate. This sink is
  that feed: a client subscribes to the observer's slow topic and never touches the
  control firehose. (Pointing a *specific* dashboard — `bb_tui` — at this topic is a
  consumer use case in the worked example, not built here.)

  Mirrors `BBMcuhub.BBHub.Sensor`'s envelope shape (a `%BB.Message{}` via
  `BB.publish/3`), but on its own topic and carrying a `BBMcuhub.Observer.Sample`
  payload (the raw slot value + context) rather than a typed control reading — the
  observability plane is separate from the control plane.

  ## Options (`new/1`)

    * `:robot` — the robot module to publish under (REQUIRED; the PubSub registry
      is per-robot).
    * `:topic` — the base topic path (a list of atoms) this observer republishes on
      (default `[:observe]`). The per-sample topic is
      `topic ++ [hub, port]` so a subscriber can listen to one slot
      (`[:observe, :sensor_hub, :pose]`) or the whole observer feed (`[:observe]`).

  This sink is stateless (the `{module, state}` state is the immutable config), so
  every sample publishes and threads the same state.
  """

  @behaviour BBMcuhub.Observer.Sink

  alias BBMcuhub.Observer.Sample

  @type state :: %{robot: module(), topic: [atom()]}

  @doc """
  Build the sink as a `{module, state}` pair ready to hand to an observer's
  `sink:` option.

      sink: BBMcuhub.Observer.Sink.PubSub.new(robot: MyRobot, topic: [:observe, :ui])
  """
  @spec new(keyword()) :: {__MODULE__, state()}
  def new(opts) do
    robot = Keyword.fetch!(opts, :robot)
    topic = Keyword.get(opts, :topic, [:observe])
    {__MODULE__, %{robot: robot, topic: topic}}
  end

  @impl BBMcuhub.Observer.Sink
  def handle_sample({hub, port} = slot, value, meta, %{robot: robot, topic: topic} = state) do
    path = topic ++ [hub, port]

    payload = %Sample{
      slot: slot,
      node: meta.node,
      port_id: meta.port_id,
      value: value,
      seq: meta.seq,
      t_dev: meta.t_dev,
      freshness: meta.freshness,
      value_type: meta.value_type,
      observer: meta.observer
    }

    BB.publish(robot, path, %BB.Message{
      monotonic_time: System.monotonic_time(:nanosecond),
      wall_time: System.system_time(:nanosecond),
      node: Node.self(),
      frame_id: port,
      payload: payload,
      robot: robot
    })

    state
  end
end
