require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/propagator/xray"
$stdout.sync = true
ep = "http://cloudwatch-agent.amazon-cloudwatch:4316/v1/traces"
puts "endpoint=#{ep}"
ex = OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: ep)
OpenTelemetry::SDK.configure do |c|
  c.service_name = "hasher-diag"
  c.id_generator = OpenTelemetry::Propagator::XRay::IDGenerator
end
tp = OpenTelemetry.tracer_provider
tr = tp.tracer("diag")
[["simple",false],["with-attrs",false],["with-error",true]].each do |name,err|
  span = nil
  tr.in_span("diag-#{name}", kind: :server) do |s|
    if name == "with-attrs"
      s.set_attribute("processing.time", 1.0)
    end
    if err
      s.set_attribute("error.type", "ValidationError")
      s.set_attribute("http.response.status_code", 500)
      s.status = OpenTelemetry::Trace::Status.error("fail")
    end
    span = s
  end
  sd = span.to_span_data
  result = ex.export([sd])
  puts "#{name}: export=#{result} trace=#{sd.trace_id.unpack1('H*')}"
end
puts "done"
