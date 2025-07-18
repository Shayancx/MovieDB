# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/services/pretty_logger'
require_relative '../../app/services/tui'

RSpec.describe PrettyLogger do
  before do
    # Reset warnings and errors before each test
    described_class.send(:clear_messages)
    # Mock TUI to be inactive by default
    allow(TUI).to receive(:active?).and_return(false)
    # Suppress puts to avoid cluttering test output
    allow($stdout).to receive(:puts)
  end

  describe '.info' do
    it 'outputs a formatted info message' do
      expect($stdout).to receive(:puts).with(/\[\e\[34mINFO\e\[0m\] Test message/)
      described_class.info('Test message')
    end
  end

  describe '.success' do
    it 'outputs a formatted success message' do
      expect($stdout).to receive(:puts).with(/\[\e\[32mSUCCESS\e\[0m\] Operation complete/)
      described_class.success('Operation complete')
    end
  end

  describe '.warn' do
    it 'adds the message to the warnings array' do
      described_class.warn('A warning')
      expect(described_class.class_variable_get(:@@warnings)).to include('A warning')
    end

    it 'outputs a message when TUI is not active' do
      expect($stdout).to receive(:puts).with(/\[\e\[33mWARN\e\[0m\] A warning/)
      described_class.warn('A warning')
    end

    it 'does not output a message when TUI is active' do
      allow(TUI).to receive(:active?).and_return(true)
      expect($stdout).not_to receive(:puts)
      described_class.warn('A warning')
    end
  end

  describe '.error' do
    it 'adds the message to the errors array' do
      described_class.error('An error')
      expect(described_class.class_variable_get(:@@errors)).to include('An error')
    end

    it 'outputs a message when TUI is not active' do
      expect($stdout).to receive(:puts).with(/\[\e\[31mERROR\e\[0m\] An error/)
      described_class.error('An error')
    end

    it 'does not output a message when TUI is active' do
      allow(TUI).to receive(:active?).and_return(true)
      expect($stdout).not_to receive(:puts)
      described_class.error('An error')
    end
  end

  describe '.debug' do
    it 'outputs a message when DEBUG env var is set' do
      ENV['DEBUG'] = '1'
      expect($stdout).to receive(:puts).with(/\[\e\[35mDEBUG\e\[0m\] Debug info/)
      described_class.debug('Debug info')
      ENV.delete('DEBUG')
    end

    it 'does not output a message when DEBUG env var is not set' do
      expect($stdout).not_to receive(:puts)
      described_class.debug('Debug info')
    end
  end

  describe '.display_summary' do
    context 'with no errors or warnings' do
      it 'displays a success message' do
        expect($stdout).to receive(:puts).with(/Completed with 0 errors and 0 warnings/)
        described_class.display_summary
      end
    end

    context 'with warnings only' do
      before { described_class.warn('Warning 1') }
      it 'displays the warnings section' do
        expect($stdout).to receive(:puts).with(/Warnings \(1\)/)
        expect($stdout).to receive(:puts).with(/• Warning 1/)
        described_class.display_summary
      end
    end

    context 'with errors only' do
      before { described_class.error('Error 1') }
      it 'displays the errors section' do
        expect($stdout).to receive(:puts).with(/Errors \(1\)/)
        expect($stdout).to receive(:puts).with(/• Error 1/)
        described_class.display_summary
      end
    end

    context 'with both warnings and errors' do
      before do
        described_class.warn('Warning 1')
        described_class.error('Error 1')
      end
      it 'displays both sections' do
        expect($stdout).to receive(:puts).with(/Warnings \(1\)/)
        expect($stdout).to receive(:puts).with(/Errors \(1\)/)
        described_class.display_summary
      end
    end

    it 'clears both arrays after display' do
      described_class.warn('A warning')
      described_class.error('An error')
      described_class.display_summary
      expect(described_class.class_variable_get(:@@warnings)).to be_empty
      expect(described_class.class_variable_get(:@@errors)).to be_empty
    end
  end
end