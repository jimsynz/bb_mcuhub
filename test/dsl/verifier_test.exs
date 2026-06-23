defmodule BBMcuhub.Dsl.VerifierTest do
  @moduledoc """
  Proves the compile-time topology verifier (`BBMcuhub.Dsl.Verifier`, §06)
  actually FIRES — it REJECTS broken topologies, not merely passes on the good
  one. Each case authors a robot module that trips exactly one of the verifier's
  checks and asserts the resulting `Spark.Error.DslError` names the offending
  pair; a positive control proves a valid robot compiles and projects a
  non-empty IR.

  ## Why `Spark.Test`, not `assert_raise`

  Spark runs DSL verifiers inside its `@after_verify` hook, where a raised
  `Spark.Error.DslError` is *caught and downgraded to a compiler warning* rather
  than propagated (see `Spark.Dsl.__verify_spark_dsl__/1` and `Spark.Test`'s own
  moduledoc). So `assert_raise Spark.Error.DslError, fn -> Code.compile_string(...) end`
  does NOT raise — the verifier fires, but the exception never escapes compile.
  `Spark.Test` is the framework's purpose-built mechanism: it registers the test
  process as a collector so verifier errors arrive as data. `assert_dsl_error/2`
  asserts the verifier produced a matching error; `refute_dsl_errors/1` asserts a
  clean compile. We assert on the error's `.message` with `=~` per the brief.

  ## Tripping OUR check, not a bb check first

  bb's own `ValidateChildSpecs` verifier also runs. For the `fresh_for < 1` case
  the real `BBMcuhub.BBHub.Sensor`/`Actuator` views type `fresh_for` as
  `:pos_integer`, so `fresh_for: 0` would also trip bb's type validation. To trip
  ONLY our check we wire in a tiny local `LaxSensor` view that types `fresh_for`
  as `:integer` (so `0` passes bb's schema and reaches our verifier alone). The
  view is never started — it only needs to compile and declare the `BB.Sensor`
  behaviour so bb's behaviour transformer is satisfied.
  """
  use ExUnit.Case, async: false

  import Spark.Test

  # --- local fixtures wired into the broken/valid robots below ---------------

  defmodule LaxSensor do
    @moduledoc """
    A throwaway `BB.Sensor` view whose `options_schema` types `fresh_for` as a
    plain `:integer`, so `fresh_for: 0` clears bb's `ValidateChildSpecs` type
    check and reaches OUR `fresh_for >= 1` check alone. Never started.
    """
    use BB.Sensor,
      options_schema: [
        hub: [type: :atom, required: true],
        port: [type: :atom, required: true],
        fresh_for: [type: :integer, required: true]
      ]

    @impl BB.Sensor
    def init(_opts), do: :ignore
  end

  defmodule MissingFlagHub do
    @moduledoc """
    A hub whose `:in` command port OMITS `has_safe_action` — the floored-role flag
    is required on every command port (ADR-0005). Placing this in a robot must trip
    `verify_safe_actions`.
    """
    use BBMcuhub.Hub

    ports do
      port(:cmd, dir: :in, type: :effort, rate: 50)
    end
  end

  defmodule BadSafeHub do
    @moduledoc """
    A floored `:in` port whose `safe_action` carries an UNKNOWN field — its
    `:effort` layout is `%{nm: f32}`, but it declares `%{nm: 0.0, torque: 0.0}`.
    The extra `:torque` is not in the value-type layout, so the verifier must
    reject it (ADR-0005), not silently default.
    """
    use BBMcuhub.Hub

    ports do
      port(:cmd,
        dir: :in,
        type: :effort,
        rate: 50,
        has_safe_action: true,
        safe_action: %{nm: 0.0, torque: 0.0}
      )
    end
  end

  defmodule StraySafeHub do
    @moduledoc """
    A `has_safe_action: false` (non-floored) port that nonetheless declares a
    `safe_action` — the role and the value disagree, a compile error (ADR-0005).
    """
    use BBMcuhub.Hub

    ports do
      port(:cmd,
        dir: :in,
        type: :effort,
        rate: 50,
        has_safe_action: false,
        safe_action: %{nm: 0.0}
      )
    end
  end

  defmodule SenseCommandHub do
    @moduledoc """
    A hub whose `:in` (command) port is typed with a SENSE value-type (`:imu`),
    which declares no `command_message` (the overridable nil default). A command
    port's value-type MUST name the BB.Message struct it accepts (finding #1 / the
    agnostic Component), so placing this in a robot must trip
    `verify_command_messages`. `has_safe_action: false` clears the floored-role
    check, so we reach the command_message check alone.
    """
    use BBMcuhub.Hub

    ports do
      port(:cmd, dir: :in, type: :imu, rate: 50, has_safe_action: false)
    end
  end

  defmodule CollideHub do
    @moduledoc """
    A hub whose two REAL port names hash to the same `port_id` (0xA6) — a genuine
    `(node, port_id)` collision in the model, expressed with real `:effort`
    layouts and no faked tables. `Contract.port_id(:collide, :p13) ==
    Contract.port_id(:collide, :p310) == 0xA6`.
    """
    use BBMcuhub.Hub

    ports do
      port(:p13, dir: :out, type: :effort, rate: 50)
      port(:p310, dir: :out, type: :effort, rate: 50)
    end
  end

  # --- the five checks -------------------------------------------------------

  describe "the verifier rejects broken topologies (it fires)" do
    test "duplicate node: two hubs on the same NODE id are rejected (§03)" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.DupNode do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:imu, BBMcuhub.Test.Fixtures.SensorHub, node: 0x09, parent: :host)

              hub(:motor, BBMcuhub.Test.Fixtures.ActuatorHub,
                node: 0x09,
                parent: :imu,
                uplink: :uart
              )
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      # names the shared node and both hub names
      assert err.message =~ "0x09"
      assert err.message =~ ":imu"
      assert err.message =~ ":motor"
      assert err.message =~ "share node"
    end

    test "reserved node: a hub on NODE 0x00 (broadcast/e-stop) is rejected (§03)" do
      err =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.ReservedNode do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:imu, BBMcuhub.Test.Fixtures.SensorHub, node: 0x00, parent: :host)
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      assert err.message =~ ":imu"
      assert err.message =~ "0x00"
      assert err.message =~ "reserved"
      assert err.message =~ "broadcast"
    end

    test "fresh_for < 1: a view with fresh_for 0 is rejected (§04)" do
      # LaxSensor lets 0 past bb's type check so we trip OUR verifier alone.
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:topology]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.FreshForZero do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:imu, BBMcuhub.Test.Fixtures.SensorHub, node: 0x02, parent: :host)
            end

            topology do
              link :base_link do
                sensor(
                  :chassis,
                  {BBMcuhub.Dsl.VerifierTest.LaxSensor, hub: :imu, port: :pose, fresh_for: 0}
                )
              end
            end
          end
        end

      # names the offending (hub, port) and the bad window
      assert err.message =~ "{:imu, :pose}"
      assert err.message =~ "fresh_for 0"
      assert err.message =~ ">= 1"
    end

    test "missing has_safe_action: a :in port without the floored-role flag is rejected (ADR-0005)" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs, :motor]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.MissingFlag do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:motor, BBMcuhub.Dsl.VerifierTest.MissingFlagHub, node: 0x05, parent: :host)
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      assert err.message =~ "{:motor, :cmd}"
      assert err.message =~ "has_safe_action"
    end

    test "ill-formed safe_action: a floored port with an unknown value-type field is rejected (ADR-0005)" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs, :motor]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.BadSafe do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:motor, BBMcuhub.Dsl.VerifierTest.BadSafeHub, node: 0x05, parent: :host)
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      assert err.message =~ "{:motor, :cmd}"
      # names the unknown field and the value-type it is not part of, rather than
      # silently defaulting (ADR-0005).
      assert err.message =~ ":torque"
      assert err.message =~ ":effort"
    end

    test "stray safe_action: a non-floored port that declares a safe_action is rejected (ADR-0005)" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs, :led]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.StraySafe do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:led, BBMcuhub.Dsl.VerifierTest.StraySafeHub, node: 0x05, parent: :host)
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      assert err.message =~ "{:led, :cmd}"
      assert err.message =~ "has_safe_action: false"
    end

    test "sense value-type on a command port: a :in port whose value-type names no command_message is rejected (finding #1)" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs, :motor]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.SenseCommand do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:motor, BBMcuhub.Dsl.VerifierTest.SenseCommandHub, node: 0x05, parent: :host)
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      # names the offending (hub, port), the sense value-type, and command_message
      assert err.message =~ "{:motor, :cmd}"
      assert err.message =~ ":imu"
      assert err.message =~ "command_message"
    end

    test "unknown port: a view naming a port no hub declares is rejected (§06)" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:topology]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.UnknownPort do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:imu, BBMcuhub.Test.Fixtures.SensorHub, node: 0x02, parent: :host)
            end

            topology do
              link :base_link do
                # :pose exists, :nonexistent does not — reconciliation must fail
                sensor(
                  :chassis,
                  {BBMcuhub.BBHub.Sensor,
                   hub: :imu, port: :nonexistent, fresh_for: 3, beat_ms: 20}
                )
              end
            end
          end
        end

      # names the unresolved (hub, port) pair
      assert err.message =~ "{:imu, :nonexistent}"
      assert err.message =~ "no hub declares that port"
    end

    test "(node, port_id) collision: two ports sharing a wire id are rejected (§03)" do
      # CollideHub's :p13 and :p310 hash to the same port_id — a real collision,
      # no faked layouts. The single hub uses a unique, non-reserved node so the
      # node checks pass and we reach verify_no_id_collision.
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.IdCollision do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:collide, BBMcuhub.Dsl.VerifierTest.CollideHub, node: 0x07, parent: :host)
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      # names the colliding wire id and both ports
      assert err.message =~ "0xA6"
      assert err.message =~ "collide: :p13"
      assert err.message =~ "collide: :p310"
      assert err.message =~ "collides"
    end

    @tag :skip
    test "frame-size ceiling: a >512-byte frame is rejected (§03) — UNEXPRESSIBLE" do
      # SKIPPED — cannot be expressed without faking the frozen layout tables,
      # which the brief forbids. The verifier's frame_size/1 sums
      # header_size + Layouts.payload_size(type) + 2. The only declared value
      # types are :imu (40B payload), :effort (4B) and :status (3B) — all frames
      # land far under the 512-byte ceiling. Naming any other `type` makes
      # `Layouts.fetch!/1` raise a KeyError inside IrTransformer *before* the
      # verifier ever runs, so there is no way to author a port whose frame
      # exceeds 512 with the real layouts. The check is still exercised by the
      # generator/drift tests against the real contract.
      flunk("unreachable — see comment")
    end
  end

  # --- the topology checks (ADR-0006) ----------------------------------------

  describe "the verifier rejects ill-formed topologies (ADR-0006)" do
    test "no root: no hub declares parent: :host is rejected" do
      # Every hub names a non-:host parent, so there is NO root. The cycle this
      # forms is irrelevant — the one-root check fires first.
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.NoRoot do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:imu, BBMcuhub.Test.Fixtures.SensorHub,
                node: 0x02,
                parent: :motor,
                uplink: :uart
              )

              hub(:motor, BBMcuhub.Test.Fixtures.ActuatorHub,
                node: 0x05,
                parent: :imu,
                uplink: :uart
              )
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      assert err.message =~ "no root"
      assert err.message =~ "parent: :host"
    end

    test "two roots: two hubs declaring parent: :host are rejected, naming them" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.TwoRoots do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:imu, BBMcuhub.Test.Fixtures.SensorHub, node: 0x02, parent: :host)
              hub(:motor, BBMcuhub.Test.Fixtures.ActuatorHub, node: 0x05, parent: :host)
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      assert err.message =~ "two+ roots"
      assert err.message =~ ":imu"
      assert err.message =~ ":motor"
    end

    test "unknown parent: a parent naming no declared hub is rejected" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs, :motor]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.UnknownParent do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:imu, BBMcuhub.Test.Fixtures.SensorHub, node: 0x02, parent: :host)

              hub(:motor, BBMcuhub.Test.Fixtures.ActuatorHub,
                node: 0x05,
                parent: :ghost,
                uplink: :uart
              )
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      assert err.message =~ ":motor"
      assert err.message =~ ":ghost"
      assert err.message =~ "not a declared hub"
    end

    test "parent cycle: hubs whose parents loop and never reach :host are rejected" do
      # imu → motor → imu: a cycle with no :host. (There is also no root, so the
      # one-root check fires first and names the absence of a root — either way
      # the broken topology cannot ship.)
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.Cycle do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:imu, BBMcuhub.Test.Fixtures.SensorHub,
                node: 0x02,
                parent: :motor,
                uplink: :uart
              )

              hub(:motor, BBMcuhub.Test.Fixtures.ActuatorHub,
                node: 0x05,
                parent: :imu,
                uplink: :uart
              )
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      # no root fires first here (no parent: :host), which is itself a refusal to
      # ship the broken topology — the point of the check.
      assert err.message =~ "no root" or err.message =~ "cycle"
    end

    test "root with an uplink: a parent: :host hub declaring uplink is rejected" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs, :imu]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.RootUplink do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:imu, BBMcuhub.Test.Fixtures.SensorHub,
                node: 0x02,
                parent: :host,
                uplink: :uart
              )
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      assert err.message =~ ":imu"
      assert err.message =~ "host UART"
    end

    test "non-root without uplink: a child that omits its uplink is rejected" do
      err =
        assert_dsl_error %Spark.Error.DslError{path: [:hubs, :motor]} do
          defmodule Elixir.BBMcuhub.Dsl.VerifierTest.MissingUplink do
            use BB, extensions: [BBMcuhub.Dsl]

            hubs do
              hub(:imu, BBMcuhub.Test.Fixtures.SensorHub, node: 0x02, parent: :host)
              hub(:motor, BBMcuhub.Test.Fixtures.ActuatorHub, node: 0x05, parent: :imu)
            end

            topology do
              link(:base_link, do: nil)
            end
          end
        end

      assert err.message =~ ":motor"
      assert err.message =~ "uplink"
    end
  end

  describe "the verifier accepts the good topology (positive control)" do
    test "the test fixture robot compiles clean and projects a non-empty IR" do
      # the library's fixture robot already compiled at load — no verifier error
      # for it, and its IR is the frozen model the generator/runtime consume
      # (ADR-0003: the library self-tests via the fixture, no example present).
      ir = BBMcuhub.Robot.Info.ir(BBMcuhub.Test.Fixtures.Robot)
      assert is_list(ir)
      assert ir != []
      # one row per declared hub port: sensor_hub :pose/:scalar, act_hub
      # :effort_cmd/:act_status
      assert length(ir) == 4
    end

    test "a minimal valid robot compiles with NO verifier error" do
      refute_dsl_errors do
        defmodule Elixir.BBMcuhub.Dsl.VerifierTest.GoodRobot do
          use BB, extensions: [BBMcuhub.Dsl]

          hubs do
            hub(:imu, BBMcuhub.Test.Fixtures.SensorHub, node: 0x02, parent: :host)
          end

          topology do
            link :base_link do
              sensor(
                :chassis_imu,
                {BBMcuhub.BBHub.Sensor, hub: :imu, port: :pose, fresh_for: 3, beat_ms: 20}
              )
            end
          end
        end
      end

      # and its IR projected non-empty (one row for the imu :pose port)
      ir = BBMcuhub.Robot.Info.ir(BBMcuhub.Dsl.VerifierTest.GoodRobot)
      assert ir != []
      assert Enum.any?(ir, &(&1.hub == :imu and &1.port == :pose))
    end
  end
end
