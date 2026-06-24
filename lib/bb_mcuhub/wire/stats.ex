defmodule BBMCUHub.Wire.Stats do
  @moduledoc """
  Tiny lock-free counter for wire-level drop/fail events (§03).

  A corrupt or short frame is *counted and dropped at the seam* — it never
  becomes a slot value (which would poison freshness, §04). These counters are
  the legible record of that: "fail into legibility", never silent loss.

  The inbound drops (`rx_drop`, `crc_fail`, `cobs_truncated`, `decode_fail`) live
  here alongside the one outbound drop, `encode_fail`: a command whose value can't
  be packed to the wire (a malformed value-type value) is counted and skipped
  rather than crashing the link drain — the floor still backstops the unsent
  command, but the *cause* stays legible instead of surfacing distantly as a floor
  firing.

  Backed by `:counters`, so `bump/1` is safe to call from the framing layer with
  no GenServer round-trip.
  """

  @counters [:rx_drop, :crc_fail, :decode_fail, :cobs_truncated, :encode_fail]
  @ref_key {__MODULE__, :ref}

  @doc "Allocate the counter array. Idempotent; safe to call at app start."
  @spec setup() :: :ok
  def setup do
    unless :persistent_term.get(@ref_key, nil) do
      ref = :counters.new(length(@counters), [:write_concurrency])
      :persistent_term.put(@ref_key, ref)
    end

    :ok
  end

  @doc "Increment a named counter by one. Auto-initialises on first use."
  @spec bump(atom()) :: :ok
  def bump(name) when name in @counters do
    :counters.add(ref(), index(name), 1)
    :ok
  end

  @doc "Read a named counter."
  @spec get(atom()) :: non_neg_integer()
  def get(name) when name in @counters, do: :counters.get(ref(), index(name))

  @doc "Read every counter as a map."
  @spec snapshot() :: %{atom() => non_neg_integer()}
  def snapshot, do: Map.new(@counters, &{&1, get(&1)})

  defp ref do
    case :persistent_term.get(@ref_key, nil) do
      nil ->
        setup()
        :persistent_term.get(@ref_key)

      ref ->
        ref
    end
  end

  defp index(name), do: Enum.find_index(@counters, &(&1 == name)) + 1
end
