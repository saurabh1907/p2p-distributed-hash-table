defmodule APPTest do
  use ExUnit.Case
  doctest APP

  test "greets the world" do
    assert APP.hello() == :world
  end
end
