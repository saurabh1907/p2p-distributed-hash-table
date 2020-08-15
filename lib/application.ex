
defmodule App do

  def main(numNodes, numRequests, failure_percent) do
    if (numNodes < 0 || numRequests < 0) do
      IO.puts "Invalid Input"
      exit(:shutdown)
    end
    Driver.start({numNodes, numRequests, failure_percent})
    GenServer.call(:driver, :init_tapestry, :infinity)
    GenServer.call(:driver, :find_max_hop)
  end
end

