defmodule BBMCUHub.Host.Transport.UART do
  @moduledoc """
  The production transport (§07): `Circuits.UART` with the COBS+CRC framing
  module, owning the host↔root-hub serial line.

  Opened `active: true` so verified bodies arrive as `{:circuits_uart, port,
  body}` in the owner's mailbox. The framing module (`BBMCUHub.Wire.FramingCOBS`)
  decodes COBS and checks the CRC at the seam, so every delivered message is a
  clean body the codec only has to parse.
  """
  @behaviour BBMCUHub.Host.Transport

  alias BBMCUHub.Wire.FramingCOBS

  @impl true
  def start_link(_owner, opts) do
    port = Keyword.fetch!(opts, :port)
    baud = Keyword.get(opts, :baud, 1_000_000)

    with {:ok, uart} <- Circuits.UART.start_link(),
         :ok <-
           Circuits.UART.open(uart, port,
             speed: baud,
             active: true,
             framing: {FramingCOBS, []}
           ) do
      {:ok, uart}
    end
  end

  @impl true
  def send(uart, body), do: Circuits.UART.write(uart, body)

  @impl true
  def close(uart), do: Circuits.UART.close(uart)
end
