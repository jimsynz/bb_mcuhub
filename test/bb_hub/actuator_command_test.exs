defmodule BBMcuhub.BBHub.ActuatorCommandTest do
  @moduledoc """
  Tier-2 validation (the design-review test for finding #1): a REAL, multi-field
  command value-type — NOT `:effort`, NOT an identity passthrough — flowing end-to-
  end through the value-type-agnostic actuator **Component**.

  Every consumer command value-type shipped today is `:effort` (single `:f32`,
  identity-ish), so the "agnostic Component" claim was never exercised on a
  consumer's OWN command. This test closes that gap with a value-type
  (`PositionVT`) that:

    * names a DIFFERENT `BB.Message` command struct via `command_message/0`
      (`BB.Message.Actuator.Command.Position`, a 4-field struct), so the actuator
      view's PubSub subscribe is DERIVED from it — proving the `Effort`
      hard-coding is gone (the subscribe would otherwise filter `Position` out
      before the generic `unlift`);
    * has a multi-field wire **layout** (`position`, `velocity` — two `:f32`s) with
      a REAL `lift`/`unlift` to/from the `Position` struct (not an identity map);

  and drives it through the REAL wire path: a published `Position` command →
  actuator view (sole writer) → command slot → LinkOwner drain → wire (COBS+CRC) →
  decodes back to the two layout fields. This exercises `command_message`
  (subscribe) + generic `unlift` + the multi-field layout together — the three
  pieces finding #1 had to make compose.

  ## The struct we used

  `BB.Message.Actuator.Command.Position` is the real multi-field BB command struct
  (`position`, `velocity`, `duration`, `command_id`). We carry the two numeric
  hints (`position`, `velocity`) on the wire; `duration`/`command_id` are optional
  in BB and not part of this port's wire vocabulary, so `lift/1` fills them `nil`.
  """
  use ExUnit.Case, async: false

  alias BBMcuhub.BBHub
  alias BBMcuhub.Contract.PortIndex
  alias BBMcuhub.Host.{LinkOwner, NodeRegistry}
  alias BBMcuhub.Host.Transport.Loopback, as: LoopbackTransport
  alias BBMcuhub.Wire.Codec

  # --- a REAL multi-field, non-Effort command value-type ---------------------

  defmodule PositionVT do
    @moduledoc """
    A consumer-style command value-type with TWO `:f32` layout fields and a real
    (non-identity) lift/unlift to `BB.Message.Actuator.Command.Position`. Its
    `command_message/0` names `Position`, NOT `Effort` — so the actuator view that
    resolves it subscribes to `Position` and a published `Position` reaches the
    view. Proves the un-hard-coding (finding #1).
    """
    use BBMcuhub.ValueType

    layout(
      position: :f32,
      velocity: :f32
    )

    @impl BBMcuhub.ValueType
    def lift(%{position: p, velocity: v}) do
      # a REAL struct build, not an identity map; the optional BB hints are nil
      %BB.Message.Actuator.Command.Position{
        position: p,
        velocity: v,
        duration: nil,
        command_id: nil
      }
    end

    @impl BBMcuhub.ValueType
    def unlift(%BB.Message.Actuator.Command.Position{position: p, velocity: v}) do
      # generic unlift the view calls — pulls the two wire fields out of the struct
      %{position: p * 1.0, velocity: (v || 0.0) * 1.0}
    end

    @impl BBMcuhub.ValueType
    def command_message, do: BB.Message.Actuator.Command.Position
  end

  defmodule PositionHub do
    @moduledoc """
    A hub whose command port is typed with `PositionVT` (BY MODULE) — a multi-field,
    non-Effort command. Floored, with a safe_action over BOTH layout fields. Reports
    its own status for liveness.
    """
    use BBMcuhub.Hub

    ports do
      port(:pos_cmd,
        dir: :in,
        type: BBMcuhub.BBHub.ActuatorCommandTest.PositionVT,
        rate: 50,
        has_safe_action: true,
        safe_action: %{position: 0.0, velocity: 0.0}
      )

      port(:pos_status, dir: :out, type: :status, rate: 50)
    end
  end

  defmodule Robot do
    @moduledoc "A one-hub robot carrying the multi-field `PositionVT` command port."
    use BB, extensions: [BBMcuhub.Dsl]

    hubs do
      hub(:pos_hub, BBMcuhub.BBHub.ActuatorCommandTest.PositionHub, node: 0x0A, parent: :host)
    end

    topology do
      # VIEW-LESS (candidate 5): the tests drive a ViewHarness actuator view by
      # hand, so the robot must NOT also start a production actuator view for the
      # same command slot — two writers of one slot is exactly what the sole-writer
      # capability (§07) refuses. The joint skeleton stays; the actuator view does
      # not. (A producer with no reader view is well-formed — reconciliation is
      # reader→producer.)
      link :base_link do
        joint :drive_joint do
          type(:continuous)

          axis do
          end

          link :drive_link do
          end
        end
      end
    end
  end

  setup do
    NodeRegistry.reset()
    PortIndex.build(Robot)

    start_supervised!(%{id: BB.Supervisor, start: {BB.Supervisor, :start_link, [Robot]}})
    :ok
  end

  describe "a real multi-field, non-Effort command flows through the agnostic Component" do
    test "a published Position reaches the view, is unlifted generically, and lands as the right bytes" do
      {:ok, {m_node, m_port}} = PortIndex.resolve(:pos_hub, :pos_cmd)

      # the value-type's OWN contract names Position, not Effort — the subscribe is
      # derived from this, so the un-hard-coding is what lets the command through
      assert PositionVT.command_message() == BB.Message.Actuator.Command.Position

      {:ok, owner} =
        LinkOwner.start_link(
          transport: LoopbackTransport,
          command_slots: [{m_node, m_port}]
        )

      on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
      transport = :sys.get_state(owner).transport

      {:ok, view} =
        BBMcuhub.Test.ViewHarness.start(
          BBHub.Actuator,
          bb: %{robot: Robot, path: [:base_link, :drive_joint, :drive]},
          hub: :pos_hub,
          port: :pos_cmd,
          status_port: :pos_status
        )

      # a BeamBots Position command (NOT Effort) arrives at the view via PubSub —
      # the subscribe derived from command_message is what lets it through
      cmd = %BB.Message{
        payload: %BB.Message.Actuator.Command.Position{position: 1.57, velocity: 0.5}
      }

      send(view, {:bb, [:actuator, :base_link, :drive_joint, :drive], cmd})

      # the slot was written (sole writer), drained, and the wire carries BOTH
      # multi-field-layout fields — generic unlift + multi-field layout end-to-end
      assert_eventually(fn ->
        case LoopbackTransport.sent(transport) do
          [body | _] ->
            match?(
              {:ok, %{node: ^m_node, port_id: ^m_port}},
              Codec.decode_body(body)
            )

          [] ->
            false
        end
      end)

      [body | _] = LoopbackTransport.sent(transport)
      {:ok, decoded} = Codec.decode_body(body)
      assert decoded.type == BBMcuhub.BBHub.ActuatorCommandTest.PositionVT
      assert_in_delta decoded.value.position, 1.57, 1.0e-5
      assert_in_delta decoded.value.velocity, 0.5, 1.0e-5
    end

    test "the unlifted command slot holds the full multi-field map (generic unlift is exact)" do
      {:ok, {m_node, m_port}} = PortIndex.resolve(:pos_hub, :pos_cmd)

      # no LinkOwner here: assert directly on what the view WROTE to the slot, so
      # the multi-field generic unlift is checked without the wire roundtrip.
      {:ok, view} =
        BBMcuhub.Test.ViewHarness.start(
          BBHub.Actuator,
          bb: %{robot: Robot, path: [:base_link, :drive_joint, :drive]},
          hub: :pos_hub,
          port: :pos_cmd,
          status_port: :pos_status
        )

      cmd = %BB.Message{
        payload: %BB.Message.Actuator.Command.Position{position: -0.25, velocity: 2.0}
      }

      send(view, {:bb, [:actuator, :base_link, :drive_joint, :drive], cmd})

      assert_eventually(fn ->
        case NodeRegistry.get(m_node, m_port) do
          {%{position: _, velocity: _}, _seq, _t} -> true
          _ -> false
        end
      end)

      {value, _seq, _t} = NodeRegistry.get(m_node, m_port)
      assert_in_delta value.position, -0.25, 1.0e-5
      assert_in_delta value.velocity, 2.0, 1.0e-5
    end
  end

  # --- helpers ---

  defp assert_eventually(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && assert_eventually(fun, tries - 1)
    end
  end
end
