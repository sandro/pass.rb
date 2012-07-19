#!/usr/bin/env ruby

# Description
# Starts the rails environment in a long running process that forks a test
# runner. The test begins running immediately as the rails environment
# has already been loaded. Useful when running a single spec over and over.

# The program will exit when a change is detected
# in the Gemfile, or the db, config, lib and vendor directories.
#
# A worker will reload the environment when a change is detected in the app/ or
# spec/ directories.
#
# Usage
# chmod +x pass
# In one terminal window, run ./pass.rb
# In another window, run the actual test, i.e. ./pass.rb spec/models/model_spec.rb

FIFO_FILE = ".pass_ipc"
`mkfifo #{FIFO_FILE}` unless test(?e, FIFO_FILE)

if ARGV.any?
  File.open(FIFO_FILE, 'w') do |f|
    f.print ARGV.join(" ")
  end
  File.open(FIFO_FILE) do |f|
    until f.eof?
      print f.getc
    end
  end
  exit
end

class Pass
  def initialize
    trap('QUIT') { print("\r"); launch_console }
  end

  def trap_int
    trap('INT') { abort("\rExit\n") }
  end

  def start
    load_environment
    trap_int
    wait_and_run
  end

  def wait_and_run
    while args = File.read(FIFO_FILE)
      puts "got args #{args.inspect}"
      run args unless args.empty?
    end
  rescue Errno::EINTR
    puts 'retrying'
    retry
  end

  def run(args)
    args = args.split(' ')
    puts "running #{args.inspect}"
    benchmark('reload') { reload_stack }
    benchmark('fork') do
      fork do
        benchmark('establish connection') do
          ActiveRecord::Base.establish_connection
        end
        out = File.open(FIFO_FILE, 'w')
        ::RSpec::Core::Runner.run args.unshift('--tty'), $stderr, out
        exit
      end
    end
    Process.waitall
  end

  def load_environment
    benchmark('rails loaded') do
      require File.expand_path('spec/spec_helper')
      ActiveRecord::Base.remove_connection
      ::RSpec.configuration.backtrace_clean_patterns << %r(#{__FILE__})
    end
  end

  def launch_console
    require 'rails/commands/console'
    Rails::Console.start(Rails.application)
    trap_int
    print "\r\n"
  end

  def reload_stack
    Rails.application.reloaders.each do |reloader|
      reloader.execute_if_updated
    end
  end

  private

  def benchmark(msg, &block)
    t = Benchmark.realtime &block
    puts "#{msg} in #{t}s"
  end
end

require 'benchmark'
require 'rb-fsevent'

Pass.new.start
