# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = 'spec/**/*_spec.rb'
  t.rspec_opts = '--format progress --fail-fast'
end

task default: :spec

desc "Run tests with timeout protection"
task :test do
  sh "bin/test"
end
