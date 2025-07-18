# frozen_string_literal: true

require 'concurrent'

# A thread-safe logger for providing formatted console output.
class PrettyLogger
  # Define color codes for different log levels
  COLORS = {
    info: "\e[34m",
    success: "\e[32m",
    warn: "\e[33m",
    error: "\e[31m",
    debug: "\e[35m"
  }.freeze
  RESET = "\e[0m"

  # Thread-safe arrays for storing warnings and errors
  @@warnings = Concurrent::Array.new
  @@errors = Concurrent::Array.new

  class << self
    def info(msg)
      log(:info, msg)
    end

    def success(msg)
      log(:success, msg)
    end

    def warn(msg)
      @@warnings << msg
      log(:warn, msg) unless TUI.active?
    end

    def error(msg)
      @@errors << msg
      log(:error, msg) unless TUI.active?
    end

    def debug(msg)
      log(:debug, msg) if ENV['DEBUG']
    end

    # Displays a summary of all warnings and errors.
    def display_summary
      puts "\n--- Import Summary ---"
      if @@warnings.empty? && @@errors.empty?
        success('Completed with 0 errors and 0 warnings.')
      else
        display_messages(@@warnings, :warn, 'Warnings')
        display_messages(@@errors, :error, 'Errors')
      end
      clear_messages
    end

    private

    # Centralized method for logging formatted messages.
    def log(level, msg)
      label = level.to_s.upcase
      puts "[#{COLORS[level]}#{label}#{RESET}] #{msg}"
    end

    # Displays a list of messages for a given type (warnings or errors).
    def display_messages(messages, level, title)
      return if messages.empty?
      puts "\n[#{COLORS[level]}#{title} (#{messages.length}):#{RESET}]"
      messages.each { |msg| puts "  • #{msg}" }
    end

    # Clears the stored warnings and errors.
    def clear_messages
      @@warnings.clear
      @@errors.clear
    end
  end
end
