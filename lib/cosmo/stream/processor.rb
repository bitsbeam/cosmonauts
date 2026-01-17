# frozen_string_literal: true

module Cosmo
  module Stream
    class Processor < ::Cosmo::Processor
      def initialize(pool, running)
        super
        @configs = {}
        @processors = {}
      end

      private

      def run_loop
        Thread.new { work_loop }
      end

      def setup
        setup_configs
        setup_processors
        setup_consumers
      end

      def work_loop
        while running?
          @consumers.each_key do |stream_name|
            break unless running?

            begin
              batch_size = @configs[stream_name][:batch_size]
              timeout = ENV.fetch("COSMO_STREAMS_FETCH_TIMEOUT", 0.1).to_f
              @pool.post { fetch_messages(stream_name, batch_size:, timeout:) }
            rescue Concurrent::RejectedExecutionError
              break # pool doesn't accept new jobs, we are shutting down
            end

            break unless running?
          end
        end
      end

      def process(stream_name, messages)
        metadata = messages.last.metadata
        processor = @processors[stream_name]
        serializer = processor.class.default_options.dig(:publisher, :serializer)
        messages = messages.map { Message.new(it, serializer:) }

        Logger.with(
          seq_stream: metadata.sequence.stream,
          seq_consumer: metadata.sequence.consumer,
          num_pending: metadata.num_pending,
          timestamp: metadata.timestamp
        ) { Logger.info "start" }

        sw = stopwatch
        processor.process(messages)
        Logger.with(elapsed: sw.elapsed_seconds) { Logger.info "done" }
      rescue StandardError => e
        Logger.debug e
        Logger.with(elapsed: sw.elapsed_seconds) { Logger.info "fail" }
      rescue Exception # rubocop:disable Lint/RescueException
        Logger.with(elapsed: sw.elapsed_seconds) { Logger.info "fail" }
        raise
      end

      def setup_configs
        @configs.merge!(
          Config.dig(:consumers, :streams).to_h {
            klass = Utils::String.safe_constantize(it[:class])
            [it[:stream].to_sym, klass ? it.merge(class: klass) : nil]
          }.compact
        )
        @configs.merge!(
          Config.system[:streams].to_h {
            [it.default_options[:stream].to_sym, it.default_options.merge(class: it)]
          }
        )
      end

      def setup_processors
        @configs.each { |s, c| @processors[s] = c[:class].new }
      end

      def setup_consumers
        @configs.each do |stream_name, config|
          subjects = config.dig(:consumer, :subjects)
          deliver_policy = Config.deliver_policy(config[:start_position])
          config, consumer_name = config.values_at(:consumer, :consumer_name)
          @consumers[stream_name] = client.subscribe(subjects, consumer_name, config.merge(deliver_policy))
        end
      end
    end
  end
end
