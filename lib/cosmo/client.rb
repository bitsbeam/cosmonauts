# frozen_string_literal: true

require "nats/client"

module Cosmo
  class Client
    def self.instance
      @instance ||= Client.new
    end

    attr_reader :client, :stream

    def initialize(nats_url: ENV.fetch("NATS_URL", "nats://localhost:4222"))
      @client = NATS.connect(nats_url)
      @stream = @client.jetstream
    end

    def publish(subject, payload, **params)
      @stream.publish(subject, payload, **params)
    end

    def maybe_create_stream(name, config)
      @stream.stream_info(name)
    rescue NATS::JetStream::Error::NotFound
      @stream.add_stream(name: name, **config)
    end
  end
end
