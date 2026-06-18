defmodule BBMcuhub.Host.Monitor do
  @moduledoc """
  Clock-free freshness (§04): trust is a counter, not a clock.

  A consumer of a `(node, port)` slot keeps a small monitor. On each of *its own*
  beats it asks one question — did this slot's `seq` advance within my `fresh_for`
  window? — and gets a binary `:fresh` / `:stale` answer. No clock is shared
  between boards; `t_dev` is never read here.

  Two invariants make this sound and safe:

    * **Born stale.** `witnessed?` starts `false`, so a freshly started or
      restarted consumer trusts *nothing* sitting in the slot until it personally
      sees `seq` advance since its own boot. A rebooted board never trusts a
      leftover reading.
    * **Advance is a plain inequality** (`seq != last_seq`). Sound only because
      every path is in-order — point-to-point UART/CAN preserve order and the
      relay is a strict FIFO byte pump (§04). No magnitude test, so counter wrap
      is a non-issue.

  Pure: `check/2` takes the monitor and the freshly-read slot row and returns the
  next monitor. The caller owns the beat and the registry read, so this is fully
  testable without a clock, a socket, or a process.
  """

  alias BBMcuhub.Host.NodeRegistry

  @enforce_keys [:node, :port, :fresh_for]
  defstruct [
    :node,
    :port,
    :fresh_for,
    last_seq: nil,
    idle: 0,
    witnessed?: false,
    status: :stale
  ]

  @type t :: %__MODULE__{
          node: 0..255,
          port: 0..255,
          fresh_for: pos_integer(),
          last_seq: 0..0xFFFF | nil,
          idle: non_neg_integer(),
          witnessed?: boolean(),
          status: :fresh | :stale
        }

  @doc """
  A new monitor for a `(node, port)` slot with a `fresh_for` window measured in
  the consumer's own beats. Born stale.
  """
  @spec new(0..255, 0..255, pos_integer()) :: t()
  def new(node, port, fresh_for) when fresh_for >= 1 do
    %__MODULE__{node: node, port: port, fresh_for: fresh_for}
  end

  @doc """
  Advance the monitor one beat by reading the slot from the registry. Convenience
  over `check_row/2` for the common case.
  """
  @spec check(t()) :: t()
  def check(%__MODULE__{} = mon) do
    check_row(mon, NodeRegistry.get(mon.node, mon.port))
  end

  @doc """
  Advance the monitor one beat against an explicit slot row (or `nil` if the slot
  has never been written). Returns the updated monitor; read `.status` for the
  fresh/stale verdict and `.witnessed?` for whether anything has ever been seen.
  """
  @spec check_row(t(), NodeRegistry.row() | nil) :: t()
  def check_row(%__MODULE__{} = mon, row) do
    seq_now = seq_of(row)

    # An *advance* is a seq that differs from the one we last saw, but only once
    # we already hold a baseline (last_seq != nil). The first beat that observes a
    # value merely records the baseline — born-stale means a value left in the
    # slot from before this consumer booted is NOT trusted until seq moves *since*
    # we started watching it.
    advanced? = seq_now != nil and mon.last_seq != nil and seq_now != mon.last_seq

    # `witnessed?` flips true on the first real advance we see — that is the
    # moment a born-stale consumer earns the right to ever be fresh.
    witnessed? = mon.witnessed? or advanced?

    idle = if advanced?, do: 0, else: mon.idle + 1
    fresh? = witnessed? and idle <= mon.fresh_for

    %{
      mon
      | last_seq: seq_now,
        idle: idle,
        witnessed?: witnessed?,
        status: if(fresh?, do: :fresh, else: :stale)
    }
  end

  @doc "Is the slot currently considered fresh?"
  @spec fresh?(t()) :: boolean()
  def fresh?(%__MODULE__{status: status}), do: status == :fresh

  defp seq_of(nil), do: nil
  defp seq_of({_value, seq, _t_dev}), do: seq
end
