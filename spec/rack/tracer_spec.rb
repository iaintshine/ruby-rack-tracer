require 'spec_helper'
require 'timeout'

RSpec.describe Rack::Tracer do
  let(:tracer) { Test::Tracer.new }
  let(:on_start_span) { spy }

  let(:ok_response) { [200, {'Content-Type' => 'application/json'}, ['{"ok": true}']] }

  let(:env) do
    Rack::MockRequest.env_for('/test/this/route', {
      method: method
    })
  end

  let(:method) { 'POST' }

  context 'when a new request' do
    it 'starts a new trace' do
      respond_with { ok_response }

      expect(tracer).to have_span("#{method}").finished
    end

    it 'passes span to downstream' do
      respond_with do |env|
        expect(env['rack.span']).to be_a(Test::Span)
        expect(env['rack.span']).not_to have_parent
        ok_response
      end
    end

    it 'calls on_start_span callback' do
      respond_with { ok_response }
      expect(on_start_span).to have_received(:call).with(instance_of(Test::Span))
    end
  end

  context 'when already traced request' do
    let(:parent_span_name) { 'parent span' }
    let(:parent_span) { tracer.start_span(parent_span_name) }

    before { inject(parent_span.context, env) }

    it 'starts a child trace' do
      respond_with { ok_response }
      parent_span.finish

      expect(tracer).to have_span("#{parent_span_name}")
      expect(tracer).to have_span("#{method}")
    end

    it 'passes span to downstream' do
      respond_with do |env|
        expect(env['rack.span']).to be_a(Test::Span)
        expect(env['rack.span']).to have_parent
        ok_response
      end
    end

    it 'calls on_start_span callback' do
      respond_with { ok_response }
      expect(on_start_span).to have_received(:call).with(instance_of(Test::Span))
    end
  end

  context 'when an exception bubbles-up through the middlewares' do
    it 'finishes the span' do
      expect { respond_with { |env| raise Timeout::Error } }.to raise_error { |_|
        expect(tracer).to have_span("#{method}")
      }
    end

    it 'marks the span as failed' do
      expect { respond_with { |env| raise Timeout::Error } }.to raise_error { |_|
        expect(tracer).to have_span.with_tag('error', true)
      }
    end

    it 'logs the error' do
      exception = Timeout::Error.new
      expect { respond_with { |env| raise exception } }.to raise_error { |thrown_exception|
        expect(tracer).to have_span("#{method}")
                            .with_log(event: 'error', :'error.object' => thrown_exception)
      }
    end

    it 're-raise original exception' do
      expect { respond_with { |env| raise Timeout::Error } }.to raise_error(Timeout::Error)
    end
  end

  def respond_with(&app)
    middleware = described_class.new(app, tracer: tracer, on_start_span: on_start_span)
    middleware.call(env)
  end

  def inject(span_context, env)
    carrier = Hash.new
    tracer.inject(span_context, OpenTracing::FORMAT_RACK, carrier)
    carrier.each do |k, v|
      env['HTTP_' + k.upcase.gsub('-', '_')] = v
    end
  end
end
