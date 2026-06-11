defmodule ThunderdomeTest do
  use ExUnit.Case
  doctest Thunderdome

  test "greets the world" do
    assert Thunderdome.hello() == :world
  end
end
