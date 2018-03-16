# frozen_string_literal: true

require 'spec_helper'

require 'elastic_apm/injectors/sidekiq'
require 'sidekiq'
require 'sidekiq/manager'
require 'sidekiq/testing'
require 'active_job'

module ElasticAPM
  RSpec.describe Injectors::SidekiqInjector do
    it 'registers' do
      registration =
        Injectors.require_hooks['sidekiq'] ||
        Injectors.installed['Sidekiq']

      expect(registration.injector).to be_a described_class
    end

    module SaveTransaction
      def self.included(kls)
        class << kls
          attr_accessor :last_transaction
        end
      end

      def set_current_transaction!
        self.class.last_transaction = ElasticAPM.current_transaction
      end
    end

    class TestingWorker
      include Sidekiq::Worker
      include SaveTransaction

      def perform
        set_current_transaction!
      end
    end

    class HardWorker < TestingWorker; end

    class ExplodingWorker < TestingWorker
      def perform
        super
        1 / 0
      end
    end

    class ActiveJobbyJob < ActiveJob::Base
      include SaveTransaction
      self.queue_adapter = :sidekiq
      self.logger = nil # stay quiet

      def perform
        set_current_transaction!
      end
    end

    before :all do
      Sidekiq::Testing.server_middleware do |chain|
        chain.add Injectors::SidekiqInjector::Middleware
      end
      Sidekiq.logger = nil # sssshh, we're testing
    end

    it 'starts when sidekiq processors do' do
      manager = Sidekiq::Manager.new concurrency: 1, queues: ['default']
      manager.start

      expect(ElasticAPM.agent).to_not be_nil

      manager.quiet

      expect(ElasticAPM.agent).to be_nil
      expect(manager).to be_stopped
    end

    context 'with an agent' do
      around do |example|
        ElasticAPM.start(enabled_injectors: %w[sidekiq])
        example.run
        ElasticAPM.stop
      end

      it 'instruments jobs' do
        Sidekiq::Testing.inline! do
          HardWorker.perform_async
        end

        transaction = HardWorker.last_transaction
        expect(transaction).to_not be_nil
        expect(transaction.name).to eq 'ElasticAPM::HardWorker'
        expect(transaction.type).to eq 'Sidekiq'

        ElasticAPM.stop
      end

      it 'reports errors', :with_fake_server do
        Sidekiq::Testing.inline! do
          expect do
            ExplodingWorker.perform_async
          end.to raise_error(ZeroDivisionError)
        end

        transaction = ExplodingWorker.last_transaction
        expect(transaction).to_not be_nil
        expect(transaction.name).to eq 'ElasticAPM::ExplodingWorker'
        expect(transaction.type).to eq 'Sidekiq'

        wait_for_requests_to_finish 1
        expect(FakeServer.requests.length).to be 1

        payload, = FakeServer.requests.last
        type = payload.dig('errors', 0, 'exception', 'type')
        expect(type).to eq 'ZeroDivisionError'
      end

      it 'knows the name of ActiveJob jobs' do
        ActiveJob::Base.queue_adapter = :sidekiq

        Sidekiq::Testing.inline! do
          ActiveJobbyJob.perform_later
        end

        transaction = ActiveJobbyJob.last_transaction
        expect(transaction).to_not be_nil
        expect(transaction.name).to eq 'ElasticAPM::ActiveJobbyJob'
      end
    end
  end
end
