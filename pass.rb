#!/usr/bin/env ruby

# Description
# Starts the rails environment in a long running process that forks a test
# runner. The test should begin running immediately as the rails environment
# has already been loaded. Useful when running a single spec over and over.
#
# Usage
# chmod +x pass
# In one terminal window, run ./pass
# In another window, run ./pass spec or ./pass spec/models/model_spec.rb

# If rb-fsevent is installed, the program will exit when a change is detected
# in the Gemfile, or the db, config, lib, vendor, directories.

FIFO_FILE = ".pass_ipc"
`mkfifo #{FIFO_FILE}` unless test(?e, FIFO_FILE)

if ARGV.any?
  File.open(FIFO_FILE, 'w') do |f|
    f.sync = true
    f.print ARGV.join(" ")
  end
  File.open(FIFO_FILE) do |f|
    until f.eof?
      print f.read(1)
    end
  end
  exit
end

class Server
  def initialize(parent)
    puts "booting rails"
    require './spec/spec_helper'
    ActiveRecord::Base.remove_connection
    puts "booted"
    wait_and_run
  end

  def wait_and_run
    puts "waiting..."
    args = File.read(FIFO_FILE).split
    run args unless args.empty?
    wait_and_run
  end

  def run(args)
    puts "running #{args.join(' ')}"
    pid = fork do
      out = File.open(FIFO_FILE, 'w')
      out.sync = true
      ActiveRecord::Base.establish_connection
      ::RSpec::Core::Runner.run args.unshift('--tty'), $stderr, out
    end
    Process.waitall
  ensure
    Process.kill 'TERM', pid rescue Errno::ESRCH
  end
end

class Watcher
  def initialize
    @parent_pid = Process.pid

    @watcher_installed = require 'rb-fsevent'
  rescue LoadError
  end

  def launch_server
    @server_pid = fork do
      Server.new(@rd)
    end
  end

  def launch_watcher
    @watcher_pid = fork do
      time = Time.now
      e = FSEvent.new
      e.watch Dir.pwd, :no_defer => true do |changes|
        diff = (time - Time.now).round
        files = %x(find #{changes.first} -mtime #{diff}s)
        if files =~ %r(Gemfile|db/|config/|lib/|vendor/)
          puts("Core file has changed.")
          Process.kill('TERM', @parent_pid)
        end
        time = Time.now
      end
      e.run
    end
  end

  def start
    launch_watcher if @watcher_installed
    launch_server
    Process.waitall
  ensure
    Process.kill 'TERM', @server_pid rescue Errno::ESRCH
    Process.kill 'TERM', @watcher_pid rescue Errno::ESRCH
  end
end

Watcher.new.start
