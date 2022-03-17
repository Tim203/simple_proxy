defmodule SimpleProxy.ConnectProxy do
  @http_options [:list, packet: 0, active: false, reuseaddr: true, packet: :http]
  @tcp_options [:binary, packet: 0, active: false, reuseaddr: true]

  @http_port 80
  @https_port 443
  @basic_auth String.to_charlist("Basic " <> Application.get_env(:simple_proxy, :auth))

  def child_spec(opts),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start, [opts]}
    }

  def start(port),
    do: {:ok, :erlang.spawn(__MODULE__, :init, [port])}

  def init(port) do
    :ets.new(:ip_info, [:public, :set, :named_table])
    add_ips()

    {:ok, listen} = :gen_tcp.listen(port, @http_options)
    do_accept(listen)
  end

  def add_ips() do
    interface = Application.get_env(:simple_proxy, :network_interface)

    {:ok, addrs} = :inet.getifaddrs()
    {_, info} = List.keyfind(addrs, interface, 0, {"", []})

    ips =
      Keyword.get_values(info, :addr)
      |> Enum.filter(fn addr -> tuple_size(addr) == 4 end)

    Enum.each(ips, fn ip -> add_ip(ip) end)
  end

  def add_ip(ip) do
    id = :ets.update_counter(:ip_info, :ip_count, 1, {:ip_count, 0})
    :ets.insert(:ip_info, {id, ip})
  end

  def do_accept(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)
    :gen_tcp.controlling_process(socket, :erlang.spawn(__MODULE__, :handle_socket, [socket]))
    do_accept(listen)
  end

  def handle_socket(socket) do
    case parse_request(socket) do
      {:proxy, request} ->
        do_proxy(request)
      {:request, request} ->
        do_request(request)
      :invalid ->
        :gen_tcp.close(socket)
    end
  end

  def parse_request(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_request, method, {:scheme, host, port}, _}} ->
        {:ok, headers} = parse_headers(socket)
        {port, _} = :string.to_integer(port)
        {:proxy, {socket, method, host, port, nil, headers}}

      {:ok, {:http_request, method, {:absoluteURI, protocol, host, port, path}, _}} ->
        {:ok, headers} = parse_headers(socket)
        port = case port do
          :undefined when :http == protocol -> @http_port
          :undefined when :https == protocol -> @https_port
          true -> port
        end
        {:ok, {socket, method, host, port, path, headers}}

      {:ok, {:http_request, method, {:abs_path, path}, _}} ->
        {:ok, headers} = parse_headers(socket)
        {:request, {socket, method, path, headers}}

      x ->
        IO.inspect(x)
        :invalid
    end
  end

  def parse_headers(socket), do: parse_headers(socket, [])

  defp parse_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, :http_eoh} ->
        {:ok, headers}
      {:ok, {:http_header, _, header, _, value}} ->
        parse_headers(socket, [{header, value} | headers])
      {:ok, {:http_error, reason}} ->
        throw(reason)
      {:error, reason} ->
        throw(reason)
    end
  end

  def string_headers(headers), do:
    :lists.map(fn {key, value} -> "#{key}:#{value}\r\n" end, headers)
    |>:lists.flatten()

  def do_request({socket, method, path, headers}) do
    if !check_auth(List.keyfind(headers, :Authorization, 0)) do
      :gen_tcp.send(socket, "HTTP/1.0 401 Unauthorized\r\n\r\n")
      :gen_tcp.close(socket)
    else
      case {method, path} do
        {:GET, '/ips'} ->
          data =
            get_ips()
            |> Enum.map(&ip_as_string/1)
            |> Jason.encode!()
          :gen_tcp.send(socket, "HTTP/1.0 200 OK\r\nContent-Length: #{String.length data}\r\nContent-Type: application/json\r\nConnection: Closed\r\n\r\n#{data}")
          :gen_tcp.shutdown(socket, :write)

          :telemetry.execute([:simple_proxy, :metrics, :requests, :local], %{add: 1}, %{source: get_ip_as_string(socket), path: path})
      end
    end
  end

  def do_proxy({socket, method, host, port, path, headers}) do
    if !check_auth(List.keyfind(headers, :"Proxy-Authorization", 0)) do
      :gen_tcp.send(socket, "HTTP/1.0 401 Unauthorized\r\n\r\n")
      :gen_tcp.close(socket)
    else
      :inet.setopts(socket, @tcp_options) # the socket is no longer http for us

      ip_header = List.keyfind(headers, 'Proxy-Ip', 0)
      our_ip = if !is_nil(ip_header) do
        {_, ip} = ip_header
        {:ok, ip} = :inet.parse_address(ip)
        ip
      else
        select_ip()
      end

      {:ok, proxy} = :gen_tcp.connect(host, port, [{:ip, our_ip} | @tcp_options])
      :telemetry.execute([:simple_proxy, :metrics, :requests], %{add: 1}, %{source: get_ip_as_string(socket), target: host})

      case method do
        'CONNECT' ->
          :gen_tcp.send(socket, "HTTP/1.0 200 Connection established\r\n\r\n")
        true ->
          :gen_tcp.send(proxy, "#{method} #{path} HTTP/1.1\r\n")
          :gen_tcp.send(proxy, string_headers(headers))
          :gen_tcp.send(proxy, "\r\n")
      end

      :gen_tcp.controlling_process(socket, :erlang.spawn(__MODULE__, :pipe, [:client, socket, proxy]))
      :gen_tcp.controlling_process(proxy, :erlang.spawn(__MODULE__, :pipe, [:server, proxy, socket]))
    end
  end

  def get_ip_as_string(socket) do
    {:ok, {ip, _}} = :inet.peername(socket)
    ip_as_string(ip)
  end

  def ip_as_string({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  def check_auth({_, auth}) when not is_nil(auth) and auth == @basic_auth, do: true
  def check_auth(_), do: false

  def select_ip do
    ip_count = :ets.lookup_element(:ip_info, :ip_count, 2)
    our_ip_index = :ets.update_counter(:ip_info, :ip_index, {2, 1, ip_count, 1}, {:ip_index, 0})
    :ets.lookup_element(:ip_info, our_ip_index, 2)
  end

  def get_ips do
    ip_count = :ets.lookup_element(:ip_info, :ip_count, 2)
    Enum.map(1..ip_count, fn index -> :ets.lookup_element(:ip_info, index, 2) end)
  end

  def pipe(from_id, from_socket, to) do
    case :gen_tcp.recv(from_socket, 0) do
      {:ok, data} ->
        :gen_tcp.send(to, data)
        pipe(from_id, from_socket, to)
      {:error, _} ->
        :gen_tcp.close(from_socket)
        :gen_tcp.close(to)
    end
  end
end
