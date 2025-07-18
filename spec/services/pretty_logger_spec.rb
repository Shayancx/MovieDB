# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/services/pretty_logger'
require_relative '../../app/services/tui'

RSpec.describe PrettyLogger do
  before do
    # Clear the class variables
    described_class.class_variable_set(:@@errors, Concurrent::Array.new)
    described_class.class_variable_set(:@@warnings, Concurrent::Array.new)
    
    # Capture stdout
    @original_stdout = $stdout
    $stdout = StringIO.new
    
    # Mock TUI
    allow(TUI).to receive(:active?).and_return(false)
  end

  after do
    $stdout = @original_stdout
  end

  describe '.info' do
    it 'outputs info message with blue color' do
      described_class.info('Test message')
      output = $stdout.string
      expect(output).to include('[INFO]')
      expect(output).to include('Test message')
      expect(output).to include("\e[34m") # Blue color
    end
  end

  describe '.success' do
    it 'outputs success message with green color' do
      described_class.success('Operation completed')
      output = $stdout.string
      expect(output).to include('[SUCCESS]')
      expect(output).to include('Operation completed')
      expect(output).to include("\e[32m") # Green color
    end
  end

  describe '.debug' do
    context 'when DEBUG environment variable is set' do
      before do
        ENV['DEBUG'] = 'true'
      end

      after do
        ENV.delete('DEBUG')
      end

      it 'outputs debug message with magenta color' do
        described_class.debug('Debug info')
        output = $stdout.string
        expect(output).to include('[DEBUG]')
        expect(output).to include('Debug info')
        expect(output).to include("\e[35m") # Magenta color
      end
    end

    context 'when DEBUG is not set' do
      before do
        ENV.delete('DEBUG')
      end

      it 'does not output debug message' do
        described_class.debug('Debug info')
        output = $stdout.string
        expect(output).to be_empty
      end
    end
  end

  describe '.warn' do
    it 'adds message to warnings array' do
      described_class.warn('Warning message')
      warnings = described_class.class_variable_get(:@@warnings)
      expect(warnings).to include('Warning message')
    end

    context 'when TUI is not active' do
      it 'outputs warning message with yellow color' do
        described_class.warn('Warning message')
        output = $stdout.string
        expect(output).to include('[WARN]')
        expect(output).to include('Warning message')
        expect(output).to include("\e[33m") # Yellow color
      end
    end

    context 'when TUI is active' do
      before do
        allow(TUI).to receive(:active?).and_return(true)
      end

      it 'does not output to stdout' do
        described_class.warn('Warning message')
        output = $stdout.string
        expect(output).to be_empty
      end

      it 'still adds to warnings array' do
        described_class.warn('Warning message')
        warnings = described_class.class_variable_get(:@@warnings)
        expect(warnings).to include('Warning message')
      end
    end
  end

  describe '.error' do
    it 'adds message to errors array' do
      described_class.error('Error message')
      errors = described_class.class_variable_get(:@@errors)
      expect(errors).to include('Error message')
    end

    context 'when TUI is not active' do
      it 'outputs error message with red color' do
        described_class.error('Error message')
        output = $stdout.string
        expect(output).to include('[ERROR]')
        expect(output).to include('Error message')
        expect(output).to include("\e[31m") # Red color
      end
    end

    context 'when TUI is active' do
      before do
        allow(TUI).to receive(:active?).and_return(true)
      end

      it 'does not output to stdout' do
        described_class.error('Error message')
        output = $stdout.string
        expect(output).to be_empty
      end

      it 'still adds to errors array' do
        described_class.error('Error message')
        errors = described_class.class_variable_get(:@@errors)
        expect(errors).to include('Error message')
      end
    end
  end

  describe '.display_summary' do
    context 'with no errors or warnings' do
      it 'displays success message' do
        described_class.display_summary
        output = $stdout.string
        expect(output).to include('--- Import Summary ---')
        expect(output).to include('Completed with 0 errors and 0 warnings.')
        expect(output).to include('[SUCCESS]')
      end
    end

    context 'with warnings only' do
      before do
        described_class.warn('Warning 1')
        described_class.warn('Warning 2')
      end

      it 'displays warnings section' do
        described_class.display_summary
        output = $stdout.string
        expect(output).to include('Warnings (2)')
        expect(output).to include('• Warning 1')
        expect(output).to include('• Warning 2')
        expect(output).to include("\e[33m") # Yellow color
      end

      it 'clears warnings after display' do
        described_class.display_summary
        warnings = described_class.class_variable_get(:@@warnings)
        expect(warnings).to be_empty
      end
    end

    context 'with errors only' do
      before do
        described_class.error('Error 1')
        described_class.error('Error 2')
        described_class.error('Error 3')
      end

      it 'displays errors section' do
        described_class.display_summary
        output = $stdout.string
        expect(output).to include('Errors (3)')
        expect(output).to include('• Error 1')
        expect(output).to include('• Error 2')
        expect(output).to include('• Error 3')
        expect(output).to include("\e[31m") # Red color
      end

      it 'clears errors after display' do
        described_class.display_summary
        errors = described_class.class_variable_get(:@@errors)
        expect(errors).to be_empty
      end
    end

    context 'with both errors and warnings' do
      before do
        described_class.warn('Warning 1')
        described_class.error('Error 1')
        described_class.warn('Warning 2')
        described_class.error('Error 2')
      end

      it 'displays both sections' do
        described_class.display_summary
        output = $stdout.string
        expect(output).to include('Warnings (2)')
        expect(output).to include('Errors (2)')
        expect(output).to include('• Warning 1')
        expect(output).to include('• Warning 2')
        expect(output).to include('• Error 1')
        expect(output).to include('• Error 2')
      end

      it 'clears both arrays after display' do
        described_class.display_summary
        errors = described_class.class_variable_get(:@@errors)
        warnings = described_class.class_variable_get(:@@warnings)
        expect(errors).to be_empty
        expect(warnings).to be_empty
      end
    end
  end

  describe 'concurrent access' do
    it 'handles concurrent errors safely' do
      threads = 10.times.map do |i|
        Thread.new { described_class.error("Error #{i}") }
      end
      threads.each(&:join)
      
      errors = described_class.class_variable_get(:@@errors)
      expect(errors.size).to eq(10)
    end

    it 'handles concurrent warnings safely' do
      threads = 10.times.map do |i|
        Thread.new { described_class.warn("Warning #{i}") }
      end
      threads.each(&:join)
      
      warnings = described_class.class_variable_get(:@@warnings)
      expect(warnings.size).to eq(10)
    end

    it 'maintains thread safety for arrays' do
      error_threads = 5.times.map do |i|
        Thread.new { described_class.error("Error #{i}") }
      end
      
      warn_threads = 5.times.map do |i|
        Thread.new { described_class.warn("Warning #{i}") }
      end
      
      (error_threads + warn_threads).each(&:join)
      
      errors = described_class.class_variable_get(:@@errors)
      warnings = described_class.class_variable_get(:@@warnings)
      
      expect(errors.size).to eq(5)
      expect(warnings.size).to eq(5)
    end
  end

  describe 'formatting' do
    it 'includes newline before warn output' do
      described_class.warn('Test')
      output = $stdout.string
      expect(output).to start_with("\n")
    end

    it 'includes newline before error output' do
      described_class.error('Test')
      output = $stdout.string
      expect(output).to start_with("\n")
    end

    it 'properly formats ANSI color codes' do
      described_class.info('Test')
      output = $stdout.string
      expect(output).to match(/\[\e\[\d+m.*\e\[0m\]/) # Color code pattern
    end
  end
end
