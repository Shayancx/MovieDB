# frozen_string_literal: true

require 'concurrent'

class PrettyLogger
  @@errors = Concurrent::Array.new
  @@warnings = Concurrent::Array.new

  def self.info(msg)
    puts "[\e[34mINFO\e[0m] #{msg}"
  end

  def self.success(msg)
    puts "[\e[32mSUCCESS\e[0m] #{msg}"
  end

  def self.debug(msg)
    puts "[\e[35mDEBUG\e[0m] #{msg}" if ENV['DEBUG']
  end

  def self.warn(msg)
    @@warnings << msg
    puts "\n[\e[33mWARN\e[0m] #{msg}" unless TUI.active?
  end

  def self.error(msg)
    @@errors << msg
    puts "\n[\e[31mERROR\e[0m] #{msg}" unless TUI.active?
  end

  def self.display_summary
    puts "\n--- Import Summary ---"
    if @@warnings.empty? && @@errors.empty?
      success('Completed with 0 errors and 0 warnings.')
    else
      unless @@warnings.empty?
        puts "\n[\e[33mWarnings (#{@@warnings.length}):\e[0m]"
        @@warnings.each { |w| puts "  • #{w}" }
      end
      unless @@errors.empty?
        puts "\n[\e[31mErrors (#{@@errors.length}):\e[0m]"
        @@errors.each { |e| puts "  • #{e}" }
      end
    end
    @@warnings.clear
    @@errors.clear
  end
end
