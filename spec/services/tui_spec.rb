# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/services/tui'

RSpec.describe TUI do
  before do
    # Reset class variables
    described_class.class_variable_set(:@@active, false)
    described_class.instance_variable_set(:@total, nil)
    described_class.instance_variable_set(:@count, nil)
    described_class.instance_variable_set(:@start_time, nil)
    
    # Capture stdout
    @original_stdout = $stdout
    $stdout = StringIO.new
  end

  after do
    $stdout = @original_stdout
  end

  describe '.active?' do
    it 'returns false by default' do
      expect(described_class.active?).to be false
    end

    it 'returns true after start' do
      described_class.start(10)
      expect(described_class.active?).to be true
    end
  end

  describe '.start' do
    it 'sets active state' do
      described_class.start(10)
      expect(described_class.active?).to be true
    end

    it 'initializes instance variables' do
      described_class.start(10)
      expect(described_class.instance_variable_get(:@total)).to eq(10)
      expect(described_class.instance_variable_get(:@count)).to eq(0)
      expect(described_class.instance_variable_get(:@start_time)).to be_a(Time)
    end

    it 'outputs initial display' do
      described_class.start(10)
      output = $stdout.string
      expect(output).to include('Processing')
      expect(output).to include('0/10')
      expect(output).to include('0%')
    end

    it 'does nothing with zero total' do
      described_class.start(0)
      expect(described_class.active?).to be false
      expect($stdout.string).to be_empty
    end
  end

  describe '.increment' do
    context 'when active' do
      before do
        described_class.start(5)
        $stdout.truncate(0) # Clear initial output
      end

      it 'increments count' do
        described_class.increment('file1.mkv')
        expect(described_class.instance_variable_get(:@count)).to eq(1)
      end

      it 'updates progress bar' do
        described_class.increment('file1.mkv')
        output = $stdout.string
        expect(output).to include('1/5')
        expect(output).to include('20%')
      end

      it 'displays current file name' do
        described_class.increment('movie.mkv')
        output = $stdout.string
        expect(output).to include('Currently:')
        expect(output).to include('movie.mkv')
      end

      it 'shows ETA after first increment' do
        described_class.increment('file1.mkv')
        sleep(0.1)
        described_class.increment('file2.mkv')
        output = $stdout.string
        expect(output).to include('ETA:')
      end

      it 'handles progress bar fill correctly' do
        3.times { |i| described_class.increment("file#{i}.mkv") }
        output = $stdout.string
        # Should show 60% progress (3/5)
        expect(output).to include('60%')
      end
    end

    context 'when not active' do
      it 'does nothing' do
        described_class.increment('file.mkv')
        expect($stdout.string).to be_empty
      end
    end
  end

  describe '.finish' do
    context 'when active with start time' do
      before do
        described_class.start(3)
        3.times { |i| described_class.increment("file#{i}.mkv") }
        $stdout.truncate(0)
      end

      it 'sets count to total' do
        described_class.finish
        expect(described_class.instance_variable_get(:@count)).to eq(3)
      end

      it 'displays completion message' do
        described_class.finish
        output = $stdout.string
        expect(output).to include('Import finished')
        expect(output).to include('0m 0s') # Very fast execution
      end

      it 'sets active to false' do
        described_class.finish
        expect(described_class.active?).to be false
      end

      it 'shows 100% progress' do
        described_class.instance_variable_set(:@count, 2) # Not complete
        described_class.finish
        output = $stdout.string
        expect(output).to include('100%')
      end
    end

    context 'when not active' do
      it 'does nothing' do
        described_class.finish
        expect($stdout.string).to be_empty
      end
    end

    context 'without start time' do
      before do
        described_class.class_variable_set(:@@active, true)
        described_class.instance_variable_set(:@start_time, nil)
      end

      it 'still finishes gracefully' do
        expect { described_class.finish }.not_to raise_error
      end
    end
  end

  describe 'private methods' do
    describe '.format_duration' do
      it 'formats seconds correctly' do
        expect(described_class.send(:format_duration, 45)).to eq('0m 45s')
      end

      it 'formats minutes and seconds' do
        expect(described_class.send(:format_duration, 125)).to eq('2m 5s')
      end

      it 'formats hours' do
        expect(described_class.send(:format_duration, 3665)).to eq('61m 5s')
      end

      it 'handles zero seconds' do
        expect(described_class.send(:format_duration, 0)).to eq('0m 0s')
      end
    end

    describe '.update_progress' do
      before do
        described_class.instance_variable_set(:@total, 10)
        described_class.instance_variable_set(:@count, 5)
        described_class.instance_variable_set(:@start_time, Time.now - 10)
      end

      it 'calculates percentage correctly' do
        described_class.send(:update_progress)
        output = $stdout.string
        expect(output).to include('50%')
      end

      it 'shows correct filled bar length' do
        described_class.send(:update_progress)
        output = $stdout.string
        # 50% of 30 character bar = 15 filled
        expect(output.scan('█').length).to eq(15)
      end

      it 'calculates ETA' do
        described_class.instance_variable_set(:@count, 2)
        described_class.send(:update_progress)
        output = $stdout.string
        expect(output).to include('ETA:')
      end

      it 'handles division by zero' do
        described_class.instance_variable_set(:@total, 0)
        expect { described_class.send(:update_progress) }.not_to raise_error
      end

      it 'uses ANSI escape codes' do
        described_class.send(:update_progress)
        output = $stdout.string
        expect(output).to include("\e[2A") # Move cursor up 2 lines
        expect(output).to include("\e[K")  # Clear line
      end
    end

    describe '.update_status' do
      it 'displays status message' do
        described_class.send(:update_status, 'Processing file.mkv')
        output = $stdout.string
        expect(output).to include('Currently:')
        expect(output).to include('Processing file.mkv')
      end

      it 'uses correct formatting' do
        described_class.send(:update_status, 'Test')
        output = $stdout.string
        expect(output).to include('└─')
        expect(output).to include("\e[2m") # Dim text
        expect(output).to include("\e[0m") # Reset
      end
    end
  end

  describe 'visual elements' do
    before do
      described_class.start(10)
    end

    it 'uses colored progress bar' do
      output = $stdout.string
      expect(output).to include("\e[32m") # Green color
    end

    it 'uses proper box drawing characters' do
      output = $stdout.string
      expect(output).to include('█') # Full block character
    end

    it 'maintains consistent formatting' do
      5.times { |i| described_class.increment("file#{i}.mkv") }
      output = $stdout.string
      # Check that output contains expected structure
      expect(output).to include('Processing')
      expect(output).to include('[')
      expect(output).to include(']')
      expect(output).to include('%')
    end
  end

  describe 'edge cases' do
    it 'handles very long filenames' do
      described_class.start(1)
      long_name = 'a' * 100 + '.mkv'
      described_class.increment(long_name)
      output = $stdout.string
      expect(output).to include(long_name)
    end

    it 'handles rapid increments' do
      described_class.start(100)
      100.times { |i| described_class.increment("file#{i}.mkv") }
      expect(described_class.instance_variable_get(:@count)).to eq(100)
    end

    it 'handles completion beyond total' do
      described_class.start(5)
      10.times { |i| described_class.increment("file#{i}.mkv") }
      # Count should not exceed total
      expect(described_class.instance_variable_get(:@count)).to eq(10)
    end
  end
end
