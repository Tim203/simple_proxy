use Mix.Config

config :simple_proxy,
  auth: Base.encode64("basic:auth"),
  network_interface: 'eth0'
