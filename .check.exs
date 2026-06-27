[
  tools: [
    # The host-compiled C harnesses (firmware/test/Makefile `all: run`, -Werror).
    # The test-only virtual-hub NIF and the C parity/drift tests already run
    # inside `mix test` (the :test elixir_make compilers gate in mix.exs), so they
    # need no entry here.
    {:c_harnesses, command: "make", cd: "firmware/test"}
  ]
]
