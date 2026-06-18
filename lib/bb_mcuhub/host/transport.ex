defmodule BBMcuhub.Host.Transport do
  @moduledoc """
  The narrow transport seam the `LinkOwner` owns (§07).

  In production this is `Circuits.UART` driving the host↔root-hub serial line with
  the `BBMcuhub.Wire.FramingCOBS` framing module, so the link owner receives
  already-decoded, CRC-clean bodies as `{:circuits_uart, port, body}` messages and
  sends bodies via `Circuits.UART.write/2`. In tests it is an in-process loopback
  so the whole host stack runs without hardware.

  A transport delivers inbound **bodies** (NODE..PAYLOAD, CRC already stripped by
  the framing layer) to the owning process's mailbox, and accepts outbound bodies
  to frame and write. The link owner never sees raw bytes or a CRC — that all
  lives below this seam (§03).
  """

  @type t :: term()
  @type body :: binary()

  @callback start_link(owner :: pid(), opts :: keyword()) :: {:ok, t()} | {:error, term()}
  @callback send(t(), body()) :: :ok | {:error, term()}
  @callback close(t()) :: :ok
end
