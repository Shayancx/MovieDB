# frozen_string_literal: true

# A simple terminal user interface for displaying progress.
class TUI
  @@active = false
  @total = 0
  @count = 0
  @start_time = nil

  class << self
    def active?
      @@active
    end

    # Starts the TUI with a given total number of items.
    def start(total)
      return if total.zero?
      @@active = true
      @total = total
      @count = 0
      @start_time = Time.now
      puts "\n" # Initial space for the TUI
      update_progress
      update_status('Initializing...')
    end

    # Increments the progress and updates the display.
    def increment(name)
      return unless @@active
      @count += 1
      @count = @total if @count > @total # Cap count at total
      update_progress
      update_status(name)
    end

    # Finishes the TUI, displaying a completion message.
    def finish
      return unless @@active
      @count = @total # Ensure progress bar is 100%
      update_progress
      elapsed = @start_time ? Time.now - @start_time : 0
      update_status("Import finished in #{format_duration(elapsed)}.")
      puts "\n" # Final newline to move past the TUI
      @@active = false
    end

    private

    # Formats a duration in seconds into a "Xm Ys" string.
    def format_duration(seconds)
      return '0m 0s' if seconds.nil? || seconds.zero?
      minutes = (seconds / 60).to_i
      secs = (seconds % 60).to_i
      "#{minutes}m #{secs}s"
    end

    # Updates the progress bar line.
    def update_progress
      bar_length = 30
      percent = @total.positive? ? (@count.to_f / @total) : 1.0
      percent = 1.0 if percent > 1.0 # Cap percentage at 100%
      filled_length = (bar_length * percent).to_i
      bar = "\e[32m#{'█' * filled_length}\e[0m#{' ' * (bar_length - filled_length)}"

      eta_str = calculate_eta
      # Go up two lines, clear them, and redraw
      print "\e[2A\e[K"
      puts "  \e[36mProcessing\e[0m [#{bar}] #{@count}/#{@total} #{(percent * 100).to_i}%#{eta_str}"
    end

    # Updates the status message line.
    def update_status(name)
      # Go to the beginning of the line and clear it
      print "\e[K"
      puts "  \e[2m└─ Currently:\e[0m #{name}"
    end

    # Calculates the estimated time remaining.
    def calculate_eta
      return '' if @count.zero? || @count >= @total || @start_time.nil?
      elapsed = Time.now - @start_time
      remaining_time = (@total - @count) * (elapsed / @count)
      " - ETA: #{format_duration(remaining_time)}"
    end
  end
end