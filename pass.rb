#!/usr/bin/env ruby

# Description
# Starts the rails environment in a long running process that forks a test
# runner. The test begins running immediately as the rails environment
# has already been loaded. Useful when running a single spec over and over.
#
# Usage
# chmod +x pass
# In one terminal window, run ./pass.rb
# In another window, run ./pass.rb spec or ./pass.rb spec/models/model_spec.rb.rb.rb

# The program will exit when a change is detected
# in the Gemfile, or the db, config, lib and vendor directories.

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

require 'benchmark'
require 'rb-fsevent'
trap('USR1', 'IGNORE')

class Server
  attr_reader :worker

  def start
    puts "booting rails"
    ENV['RAILS_ENV'] ||= 'test'
    t = Benchmark.realtime do
      require File.expand_path('config/application')
      require 'rspec/rails'
      ActiveRecord::Base.remove_connection
    end
    puts "rails booted in #{t}"
    trap('USR1') { load_worker }
    load_worker
    wait_and_run
  end

  def load_worker
    @worker.kill if @worker
    @worker = Worker.new.load
  end

  def wait_and_run
    while args = File.read(FIFO_FILE)
      worker.run args unless args.empty?
      load_worker
    end
  rescue Errno::EINTR
    retry
  end

  class Worker
    attr_reader :pid

    def initialize
      @pid = nil
      @rd, @wd = IO.pipe
    end

    def kill
      Process.kill 'TERM', pid rescue Errno::ESRCH
    end

    def load
      @pid = fork do
        trap('USR1', 'IGNORE')
        @wd.close
        t = Benchmark.realtime do
          require File.expand_path('spec/spec_helper')
        end
        puts "worker loaded environment in #{t}"
        args = @rd.read.split
        run_tests(args)
        @rd.close
        exit
      end
      @rd.close
      self
    end

    def run(args)
      @wd.write(args)
      @wd.close
      Process.waitall
    ensure
      Process.kill 'TERM', @pid rescue Errno::ESRCH
    end

    protected

    # child process runs the tests
    def run_tests(args)
      puts "running #{args.join(' ')}"
      out = File.open(FIFO_FILE, 'w')
      ::RSpec::Core::Runner.run args.unshift('--tty'), $stderr, out
    rescue Errno::EPIPE
    end
  end

end

class Watcher
  attr_reader :fsevent, :callbacks

  def initialize
    @fsevent = FSEvent.new
    @callbacks = {}
  end

  def register(regexp, &block)
    callbacks[regexp] = block
  end

  def start
    time = Time.now
    fsevent.watch Dir.pwd, :no_defer => true do |changes|
      diff = (time - Time.now).round
      files = %x(find #{changes.first} -mtime #{diff}s)
      callbacks.each do |regexp, block|
        block.call if files =~ regexp
      end
      time = Time.now
    end
    fsevent.run
  end

end

class Pass
  def initialize
    @parent_pid = Process.pid
  end

  def launch_server
    @server_pid = fork { Server.new.start }
  end

  def launch_watcher
    @watcher_pid = fork do
      w = Watcher.new
      w.register %r(Gemfile|db/|config/|lib/|vendor/) do
        puts("Core file has changed.")
        Process.kill('TERM', -Process.getpgrp)
      end
      w.register %r(app/|spec/) do
        Process.kill('USR1', -Process.getpgrp)
      end
      w.start
    end
  end

  def start
    launch_server
    launch_watcher
    Process.waitall
  ensure
    Process.kill 'TERM', @server_pid rescue Errno::ESRCH
    Process.kill 'TERM', @watcher_pid rescue Errno::ESRCH
  end
end

Pass.new.start
