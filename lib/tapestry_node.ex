defmodule TapestryNode do
  use GenServer

  def start({node_id, backpointers, neighbour_map, levels, base, data_store}) do
    args = {node_id, backpointers, neighbour_map, levels, base, data_store}
    GenServer.start_link(__MODULE__, args, name: :"#{node_id}")
  end

  def init({node_id, backpointers, neighbour_map, levels, base, data_store}) do
    #State -> id, backpointers_set(need_to_know), neighbour_map_map, levels(id_length), data_store_map
    state = %{self_id: node_id, backpointers: backpointers, neighbour_map: neighbour_map, levels: levels, base: base, data_store: data_store, active_status: true}
    {:ok, state}
  end

  def handle_cast({:route_to_node, destination, hops, prefix}, state)do
    self_id = String.pad_leading(state.self_id, state.levels, "0")
    destination = String.pad_leading(destination, state.levels, "0")
    if destination == self_id do
      GenServer.cast(:driver,{:hops, hops})
    else
      prefix_matched = prefix_match(self_id, destination, 0)
      current_level = Map.get(state.neighbour_map, prefix_matched)
      current_level = Enum.filter(current_level,& !is_nil(&1))
      next_node = Enum.find(current_level, fn i->
        String.at(i, prefix_matched) == String.at(destination, prefix_matched)
      end)
      GenServer.cast(:"#{next_node}",{:route_to_node, destination, hops+1, prefix+1})
    end
    {:noreply, state}
  end

  def handle_call({:network_join, gateway_node}, _from, state) do
    #Obtain neighbour_map by routing to surrogate
    {neighbour_map, surrogate_node} = loop_join(state.self_id, state.levels, gateway_node, state.neighbour_map, 0)

    #move surroge data store to new node
    data_store = GenServer.call(:"#{surrogate_node}", {:transfer_data_store, state.self_id})


    #notify step
    # 1: notify surrogate backpointers
    surrogate_backpointers = GenServer.call(:"#{surrogate_node}", :get_backpointers)
    Enum.each(surrogate_backpointers, fn x->
      GenServer.call(:"#{x}", {:notify, state.self_id})
    end)

    # 2: notify neighbours
    loop_neighbour_map(neighbour_map, fn x->
      if(x != nil) do GenServer.call(:"#{x}", {:notify, state.self_id}) end
    end)

    updated_state = Map.put(state, :data_store, data_store)
    updated_state = Map.put(updated_state, :neighbour_map, neighbour_map)
    {:reply, {:ok}, updated_state}
  end

  def handle_call({:publish_object, data}, _from, state) do
    updated_state = Map.put(state, :data_store, Map.put(state.data_store, state.self_id, data))
    {:reply, :ok, updated_state}
  end

  def handle_call({:unpublish_object}, _from, state) do
    updated_state = Map.put(state, :data_store, Map.delete(state.data_store, state.self_id))
    {:reply, :ok, updated_state}
  end

  def handle_call({:transfer_data_store, id}, _from, state) do
    to_drop = Enum.filter(state.data_store, fn {k,v}-> ((v-id)>=0) end)
    updated_state = Map.put(state, :data_store, Map.drop(state.data_store, to_drop))
    {:reply, to_drop, updated_state}
  end

  def handle_call({:notify, node_id}, _from, state) do
    {updated_neighbour_map, to_drop, node_id_used_ack} = loop_map_row(0, state.levels, state.neighbour_map, state.base, MapSet.new(), node_id, false, state.self_id)
    Enum.each(to_drop, fn x->
      if(x != nil) do GenServer.call(:"#{x}", {:remove_backpointers, state.self_id}) end
    end)
    if(node_id_used_ack) do
      GenServer.cast(:"#{node_id}", {:update_backpointers, state.self_id})
    end

    updated_state = Map.put(state, :neighbour_map, updated_neighbour_map)
    # return acknowledge if the caller id got a place in routing table. used to update backpointers of caller
    {:reply, node_id_used_ack, updated_state}
  end


  def handle_call({:get_neighbour_map_level, levels}, _from, state) do
    {:reply, Map.fetch(state.neighbour_map, levels), state}
  end

  def handle_call(:get_neighbour_map, _from, state) do
    {:reply, state.neighbour_map, state}
  end

  def handle_call({:get_closest_neighbour, prefix_length},_from, state) do
    neighbour_map_row = Map.get(state.neighbour_map, prefix_length + 1)
    if(neighbour_map_row == nil) do
      {:reply, nil, state}
    else
      neighbour_map_row = Enum.filter(neighbour_map_row,  fn x-> (x != nil) end)
      closest = Enum.min(neighbour_map_row, fn -> nil end)
      {:reply, closest, state}
    end
  end

  def handle_call(:get_backpointers, _from, state) do
    {:reply, state.backpointers, state}
  end

  def handle_cast({:update_backpointers, node_id}, state) do
    updated_backpointers = MapSet.put(state.backpointers, node_id)
    updated_state = Map.put(state, :backpointers, updated_backpointers)
    {:noreply, updated_state}
  end

  def handle_call({:update_backpointers, node_id},_from, state) do
    updated_backpointers = MapSet.put(state.backpointers, node_id)
    updated_state = Map.put(state, :backpointers, updated_backpointers)
    {:reply, :ok, updated_state}
  end

  def handle_call({:remove_backpointers, node_id},_from, state) do
    updated_backpointers = MapSet.delete(state.backpointers, node_id)
    updated_state = Map.put(state, :backpointers, updated_backpointers)
    {:reply, :ok, updated_state}
  end

  def handle_call(:stablize, _from, state) do
    loop_neighbour_map(state.neighbour_map, fn x -> if(x != nil) do GenServer.call(:"#{x}", {:update_backpointers, state.self_id}) end end)
    {:reply, :ok, state}
  end

  def loop_map_row(start, levels, neighbour_map, base, to_drop, node_id, node_id_ack, self_id) do
    if(start >= levels) do
      {neighbour_map, to_drop, node_id_ack}
    else
      neighbour_map_row = Map.get(neighbour_map, start)
      {neighbour_map_row, to_drop, node_id_ack} = loop_map_column(0, base, levels, neighbour_map_row, to_drop, node_id, node_id_ack, self_id)
      updated_neighbour_map = Map.put(neighbour_map, start, neighbour_map_row)

      loop_map_row(start + 1, levels, updated_neighbour_map, base, to_drop, node_id, node_id_ack, self_id)
    end
  end

  def loop_map_column(start, columns, levels, neighbour_row, to_drop, node_id, node_id_ack, self_id) do
    if(start >= columns) do
      {neighbour_row, to_drop, node_id_ack}
    else
      base = columns
      column_value = Enum.at(neighbour_row, start)
      node_id = String.pad_leading(node_id, levels,"0")
      fix_prefix = String.slice(self_id, 0, start) <> Integer.to_string(start, base)
      start_val = fix_prefix |> String.pad_trailing(levels,"0")
      end_val = fix_prefix |> String.pad_trailing(levels, Integer.to_string(base - 1, base))

      if(node_id >= start_val && node_id <= end_val && (column_value == nil || node_id < String.pad_leading(column_value, levels,"0"))) do
        loop_map_column(start + 1, columns, levels, List.replace_at(neighbour_row, start, node_id), MapSet.put(to_drop, column_value), node_id, true, self_id)
      else
        MapSet.delete(to_drop, column_value)
        loop_map_column(start + 1, columns, levels, neighbour_row, to_drop, node_id, node_id_ack, self_id)
      end
    end
  end

  def loop_neighbour_map(neighbour_map, fun) do
    Enum.each(neighbour_map, fn {k_r,v_r}->
      Enum.each(v_r, fn x->
          fun.(x)
      end)
    end)
  end

  def loop_join(self_id, levels, current_hop, neighbour_map, prefix_length) do
    #get current hop's selected level routing table
    {:ok, neighbour_row} = GenServer.call(:"#{current_hop}", {:get_neighbour_map_level, prefix_length})
    updated_neighbour_row = Enum.map(neighbour_row, fn x ->
      if(x == nil) do
        nil
      else
        closest_secondry_neighbour = GenServer.call(:"#{x}", {:get_closest_neighbour, prefix_length})
        if(closest_secondry_neighbour == nil) do x else min(x, closest_secondry_neighbour) end
      end end)
    updated_map = Map.put(neighbour_map, prefix_length, updated_neighbour_row)

    filter_row = Enum.filter(updated_neighbour_row, fn x ->
      x != nil && String.pad_leading(x, levels, "0") <= String.pad_leading(self_id, levels, "0")
    end)
    next_hop = Enum.max(filter_row, fn -> nil end)

    if(next_hop != nil && prefix_length < levels - 1) do
      loop_join(self_id, levels, next_hop, updated_map, prefix_length + 1)
    else
      loop_neighbour_map(neighbour_map, fn x->
        if(x != nil) do GenServer.call(:"#{x}", {:update_backpointers, x}) end
      end)
      {updated_map, current_hop}
    end
  end

  def prefix_match(string1,string2,num) do
    if(String.at(string1,num) == String.at(string2,num)) do
      prefix_match(string1,string2,num+1)
    else
      num
    end
  end
end
