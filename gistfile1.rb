#!/usr/bin/env ruby

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

    @listener_installed = require 'listen'
  rescue LoadError
  end

  def launch_server
    @server_pid = fork do
      Server.new(@rd)
    end
  end

  def launch_watcher
    @watcher_pid = fork do
      watcher = Listen.to('.').ignore('tmp/').change do |modified, added|
        modified.each do |file|
          if file =~ %r(Gemfile|db/structure.sql)
            puts("Core file #{file} has changed.")
            Process.kill('TERM', @parent_pid)
          end
        end
      end
      watcher.start
    end
  end

  def start
    launch_watcher if @listener_installed
    launch_server
    Process.waitall
  ensure
    Process.kill 'TERM', @server_pid rescue Errno::ESRCH
    Process.kill 'TERM', @watcher_pid rescue Errno::ESRCH
  end
end

Watcher.new.start
