# frozen_string_literal: true

class TUI
  @@active = false

  def self.active?
    @@active
  end

  def self.start(total)
    return if total.zero?

    @@active = true
    @total = total
    @count = 0
    @start_time = Time.now
    puts "\n"
    update_progress
    update_status('Initializing...')
  end

  def self.increment(name)
    return unless @@active

    @count += 1
    update_progress
    update_status(name)
  end

  def self.finish
    return unless @@active && @start_time

    @count = @total if @count < @total
    update_progress
    elapsed = Time.now - @start_time
    update_status("Import finished in #{format_duration(elapsed)}.")
    puts "\n"
    @@active = false
  end

  class << self
    private

    def format_duration(seconds)
      minutes = (seconds / 60).to_i
      secs = (seconds % 60).to_i
      "#{minutes}m #{secs}s"
    end

    def update_progress
      bar_length = 30
      percent = @total.positive? ? (@count.to_f / @total) : 1.0
      filled_length = (bar_length * percent).to_i
      bar = "\e[32m#{'█' * filled_length}\e[0m#{' ' * (bar_length - filled_length)}"

      elapsed = Time.now - @start_time
      eta = if @count.positive? && @count < @total
              remaining_time = (@total - @count) * (elapsed / @count)
              " - ETA: #{format_duration(remaining_time)}"
            else
              ''
            end

      print "\e[2A\e[K"
      puts "  \e[36mProcessing\e[0m [#{bar}] #{@count}/#{@total} #{(percent * 100).to_i}%#{eta}"
    end

    def update_status(name)
      print "\e[K"
      puts "  \e[2m└─ Currently:\e[0m #{name}"
    end
  end
end
