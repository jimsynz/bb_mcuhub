defmodule BBMCUHub.Observer.Sample do
  @moduledoc """
  The payload an observer's PubSub-republish sink puts on the wire-bus
  (`BBMCUHub.Observer.Sink.PubSub`).

  An observer's v1 sample-state mode hands the **raw slot value** to its sink (no
  value-type lift — `filter`/`project` are deferred, ADR-0004). But BeamBots'
  `BB.publish/3` keys message-type filtering on `payload.__struct__`, so a republish
  needs a payload struct. This is that struct: a thin, self-describing envelope
  carrying the raw value plus the sample's context, so a subscriber gets the value
  AND knows which slot / `seq` / freshness it came from — without the observer
  having to lift via the value-type (the seam for that lift is kept, but unused in
  v1).

  It is deliberately NOT one of the typed `BB.Message.Sensor.*` payloads a Component
  view publishes: the observability plane is categorically separate from the control
  plane (CONTEXT.md · *Control plane · observability plane*), and a sample is "the
  raw value at slot X, seq N, fresh by my cadence", not a typed control reading.
  """

  @type t :: %__MODULE__{
          slot: {hub :: atom(), port :: atom()},
          node: 0..255,
          port_id: 0..255,
          value: term(),
          seq: 0..0xFFFF,
          t_dev: non_neg_integer(),
          freshness: :fresh | :stale,
          value_type: module(),
          observer: term()
        }

  defstruct [
    :slot,
    :node,
    :port_id,
    :value,
    :seq,
    :t_dev,
    :freshness,
    :value_type,
    :observer
  ]
end
