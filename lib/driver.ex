defmodule Driver do
  use GenServer

  def start(args) do
    GenServer.start_link(__MODULE__, args, name: :driver)
  end

  def init({numNodes, numRequests, failure_percent}) do
    # State : numNodes, numRequests, active_nodes, max_hops
    state = %{numNodes: numNodes, numRequests: numRequests, active_state: [], max_hops: 0, counter: 0, failure_percent: failure_percent}
    {:ok, state}
  end

  def handle_call(:init_tapestry, _from, state) do
    base = 16
    levels = 8

    active_nodes = Enum.map(1..state.numNodes, fn x-> :crypto.hash(:sha,Integer.to_string(x)) |> Base.encode16|>String.slice(0..(levels - 1)) end)
    active_nodes = Enum.uniq(active_nodes)
    state = Map.put(state, :active_nodes, active_nodes)

    dynamic_node = Enum.at(active_nodes, div(state.numNodes,2))
    active_nodes = List.delete_at(active_nodes, div(state.numNodes,2))

    tasks =
      for i <- 0..(Enum.count(active_nodes)-1) do
       Task.async( fn ->
        current_node = Enum.at(active_nodes,i)
        node_name = current_node |> String.pad_leading(levels, "0")
        neighbour_map = loop_map_row(0, levels, %{}, base, active_nodes, current_node)
        TapestryNode.start({node_name, MapSet.new(),neighbour_map, levels, base, %{}})
        end)
      end
      Enum.map(tasks,fn x->Task.await(x,:infinity) end)

    Enum.each(active_nodes, fn current_node ->
      GenServer.call(:"#{current_node}", :stablize)
    end)
    # Network join for one node using a gateway node

    join_new_node(dynamic_node, Enum.random(active_nodes), base, levels)
    {:reply, :ok, state}

  end

  def handle_call(:find_max_hop, _from, state) do
    Enum.each(state.active_nodes , fn x->
      for i <- 1..state.numRequests do
        target = Enum.random(state.active_nodes)
        GenServer.cast(:"#{x}",{:route_to_node, target, 0,0})
      end
    end)
    {:reply, :ok, state}
  end

  def join_new_node(new_node, gateway_node, base, levels) do
    TapestryNode.start({new_node, MapSet.new(),%{}, levels, base, %{}})
    GenServer.call(:"#{new_node}", {:network_join, gateway_node})
  end

  def loop_map_row(start, levels, neighbour_map, base, active_nodes, current_node) do
    if(start >= levels) do
      neighbour_map
    else
      neighbour_map_row = Enum.map(0..(base-1), fn column ->
        current_node = String.pad_leading(current_node, levels,"0")

        fix_prefix = String.slice(current_node, 0, start) <> Integer.to_string(column, base)
        start_val = fix_prefix |> String.pad_trailing(levels,"0")
        end_val = fix_prefix |> String.pad_trailing(levels, Integer.to_string(base - 1, base))

        filter = Enum.filter(active_nodes, fn x ->
          x = String.pad_leading(x,levels,"0")
          x != current_node &&  x >= start_val && x <= end_val
        end)
        Enum.min(Enum.map(filter, fn x-> String.pad_leading(x,levels,"0") end), fn -> nil end)
     end)
     updated_neighbour_map = Map.put(neighbour_map, start, neighbour_map_row)

     loop_map_row(start + 1, levels, updated_neighbour_map, base, active_nodes, current_node)
    end
  end

  @impl true
  def handle_cast({:hops, hops}, state) do
    if(state.counter == div((state.numNodes * state.numRequests),2)) do
      IO.puts("Max Hops : #{state.max_hops}")
    end
    updated_state = Map.put(state, :counter, state.counter + 1)
    if( state.max_hops < hops) do
      updated_state = Map.put(updated_state, :max_hops, hops)
      {:noreply, updated_state}
    else
      {:noreply, updated_state}
    end
  end

end

