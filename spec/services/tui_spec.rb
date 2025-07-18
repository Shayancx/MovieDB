# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/services/tui'

RSpec.describe TUI do
  before do
    # Reset state before each test
    described_class.class_variable_set(:@@active, false)
    described_class.instance_variable_set(:@total, 0)
    described_class.instance_variable_set(:@count, 0)
    described_class.instance_variable_set(:@start_time, nil)
    # Suppress puts to avoid cluttering test output
    allow($stdout).to receive(:puts)
    allow($stdout).to receive(:print)
  end

  describe '.start' do
    it 'activates the TUI and initializes variables' do
      described_class.start(10)
      expect(described_class.active?).to be true
      expect(described_class.instance_variable_get(:@total)).to eq(10)
    end

    it 'does not start if total is zero' do
      described_class.start(0)
      expect(described_class.active?).to be false
    end
  end

  describe '.increment' do
    before { described_class.start(10) }

    it 'increments the count and updates the display' do
      expect(described_class).to receive(:update_progress)
      expect(described_class).to receive(:update_status).with('File 1')
      described_class.increment('File 1')
      expect(described_class.instance_variable_get(:@count)).to eq(1)
    end

    it 'does not do anything if not active' do
      described_class.class_variable_set(:@@active, false)
      expect(described_class).not_to receive(:update_progress)
      described_class.increment('File 1')
    end

    it 'caps the count at the total' do
      15.times { described_class.increment('File') }
      expect(described_class.instance_variable_get(:@count)).to eq(10)
    end
  end

  describe '.finish' do
    before { described_class.start(10) }

    it 'deactivates the TUI and displays a final message' do
      expect(described_class).to receive(:update_status).with(/Import finished/)
      described_class.finish
      expect(described_class.active?).to be false
    end

    it 'ensures the progress bar is at 100%' do
      described_class.increment('File 1')
      described_class.finish
      expect(described_class.instance_variable_get(:@count)).to eq(10)
    end

    it 'does not do anything if not active' do
      described_class.class_variable_set(:@@active, false)
      expect(described_class).not_to receive(:update_status)
      described_class.finish
    end
  end

  describe 'private methods' do
    describe '.format_duration' do
      it 'formats seconds into a string' do
        expect(described_class.send(:format_duration, 125)).to eq('2m 5s')
        expect(described_class.send(:format_duration, 30)).to eq('0m 30s')
        expect(described_class.send(:format_duration, 0)).to eq('0m 0s')
      end
    end

    describe '.calculate_eta' do
      it 'calculates ETA correctly' do
        start_time = Time.now
        described_class.instance_variable_set(:@start_time, start_time)
        described_class.instance_variable_set(:@total, 100)
        described_class.instance_variable_set(:@count, 10)
        allow(Time).to receive(:now).and_return(start_time + 10)
        expect(described_class.send(:calculate_eta)).to include('ETA: 1m 30s')
      end

      it 'returns an empty string when count is zero' do
        described_class.start(10)
        described_class.instance_variable_set(:@count, 0)
        expect(described_class.send(:calculate_eta)).to eq('')
      end
    end
  end
end
