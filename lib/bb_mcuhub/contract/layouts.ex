defmodule BBMcuhub.Contract.Layouts do
  @moduledoc """
  The shared source of truth for value-type wire layouts (§06).

  Each value type maps to an **ordered list of `{field, wire_type}`** — and *that*
  list, not any hand-written encoder, is what both languages render. The Elixir
  codec, the C struct, and the parity-vector bytes are all derived from the same
  list, so a reordered field is a single-line change that ripples everywhere
  consistently.

  Per the project decision to **reuse existing BeamBots definitions**, the field
  order here mirrors the real `bb` message structs the views lift to/from (§09):

    * `:imu` mirrors `BB.Message.Sensor.Imu` — a unit quaternion (w,x,y,z) plus
      two `BB.Math.Vec3`s (angular velocity, linear acceleration). Each component
      is an `:f32` on the wire (compact, one CAN-FD frame); the view lifts via
      `BB.Math.Quaternion.new/4` and `BB.Math.Vec3.new/3` and reads back through
      the accessors. (Quaternion.new normalises, so an already-unit orientation
      round-trips cleanly — which IMU orientation always is.)
    * `:effort` mirrors `BB.Message.Actuator.Command.Effort` — a single `:f32`
      torque/force in motor-space.
    * `:status` is the actuator's reported truth (§05): `applied_seq` + a
      `floored?` flag, the source of "is this hub actually driving?".

  Wire types and their byte widths (big-endian, the network/AVR-friendly order):

      :f32 → 4 · :f64 → 8 · :u8 → 1 · :u16 → 2 · :u32 → 4 · :u64 → 8 · :bool → 1
  """

  @type wire_type :: :f32 | :f64 | :u8 | :u16 | :u32 | :u64 | :bool
  @type layout :: [{atom(), wire_type()}]

  @widths %{f32: 4, f64: 8, u8: 1, u16: 2, u32: 4, u64: 8, bool: 1}

  @layouts %{
    imu: [
      # orientation — BB.Math.Quaternion (w,x,y,z), already normalised
      qw: :f32,
      qx: :f32,
      qy: :f32,
      qz: :f32,
      # angular_velocity — BB.Math.Vec3, rad/s
      wx: :f32,
      wy: :f32,
      wz: :f32,
      # linear_acceleration — BB.Math.Vec3, m/s²
      ax: :f32,
      ay: :f32,
      az: :f32
    ],
    effort: [
      # BB.Message.Actuator.Command.Effort.effort — Nm or N, motor-space
      nm: :f32
    ],
    status: [
      # the actuator's reported truth (§05)
      applied_seq: :u16,
      floored: :bool
    ]
  }

  @doc "All known value-type layouts, keyed by type name."
  @spec all() :: %{atom() => layout()}
  def all, do: @layouts

  @doc "The ordered `{field, wire_type}` layout for a value type."
  @spec fetch!(atom()) :: layout()
  def fetch!(type), do: Map.fetch!(@layouts, type)

  @doc "Byte width of a wire type."
  @spec width(wire_type()) :: pos_integer()
  def width(wire_type), do: Map.fetch!(@widths, wire_type)

  @doc "Total payload byte size of a value type."
  @spec payload_size(atom()) :: non_neg_integer()
  def payload_size(type) do
    type |> fetch!() |> Enum.reduce(0, fn {_f, wt}, acc -> acc + width(wt) end)
  end

  @doc "All wire types and their widths (for the C/codec renderers)."
  @spec widths() :: %{wire_type() => pos_integer()}
  def widths, do: @widths
end
