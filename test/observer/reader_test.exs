defmodule BBMCUHub.Host.Registry.ReaderTest do
  @moduledoc """
  The read-only registry capability (ADR-0004): only `get`/`dump`, no `put`, so an
  observer handed a `Reader` cannot represent a slot write.
  """
  use ExUnit.Case, async: false

  alias BBMCUHub.Host.NodeRegistry
  alias BBMCUHub.Host.Registry.Reader

  setup do
    NodeRegistry.reset()
    :ok
  end

  describe "the default reader delegates the read-only half of NodeRegistry" do
    test "get/3 returns the slot row, or nil for a never-written slot" do
      reader = Reader.default()
      assert Reader.get(reader, 0x02, 0x10) == nil

      NodeRegistry.put(0x02, 0x10, %{az: 9.81}, 5, 7)
      assert Reader.get(reader, 0x02, 0x10) == {%{az: 9.81}, 5, 7}
    end

    test "dump/1 returns every row keyed by {node, port_id}" do
      reader = Reader.default()
      assert Reader.dump(reader) == %{}

      NodeRegistry.put(0x02, 0x10, %{az: 1.0}, 1, 0)
      NodeRegistry.put(0x05, 0x7B, %{nm: 0.5}, 2, 0)

      assert Reader.dump(reader) == %{
               {0x02, 0x10} => {%{az: 1.0}, 1, 0},
               {0x05, 0x7B} => {%{nm: 0.5}, 2, 0}
             }
    end
  end

  describe "the capability is structurally read-only" do
    test "a Reader exposes only get/dump fields — there is no put" do
      reader = Reader.default()
      assert Map.keys(reader) |> Enum.sort() == [:__struct__, :dump, :get]
      refute Map.has_key?(reader, :put)
    end

    test "the Reader module exports no write function" do
      exports = Reader.__info__(:functions) |> Keyword.keys() |> Enum.uniq()
      assert :get in exports
      assert :dump in exports
      assert :default in exports
      refute :put in exports
    end

    test "the Observer never calls a slot write (it reaches the registry only via the Reader)" do
      # structural proof: the observer reaches the registry only through the Reader
      # capability, so a slot write is unrepresentable in observer code. The
      # moduledoc may NAME NodeRegistry in prose; what must not exist is a write
      # CALL or an alias that would let one slip in.
      src = File.read!("lib/bb_mcuhub/observer.ex")
      # no slot-write call: the only write to the registry is NodeRegistry.put, and
      # the observer never names it. (`Keyword.put` on its options is unrelated.)
      refute src =~ "NodeRegistry.put"
      # the registry is reached only through the Reader capability, never aliased
      # directly, so the observer cannot even spell a slot write.
      refute src =~ "alias BBMCUHub.Host.NodeRegistry"
      assert src =~ "alias BBMCUHub.Host.Registry.Reader"
      assert src =~ "Reader.get("
    end
  end

  describe "a fake reader can be injected" do
    test "any struct with get/dump funcs works as a capability" do
      fake = %Reader{
        get: fn _node, _port -> {%{x: 1}, 9, 0} end,
        dump: fn -> %{scripted: true} end
      }

      assert Reader.get(fake, 1, 2) == {%{x: 1}, 9, 0}
      assert Reader.dump(fake) == %{scripted: true}
    end
  end
end
