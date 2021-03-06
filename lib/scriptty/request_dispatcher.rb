# = Request dispatcher
# Copyright (C) 2010  Infonium Inc.
#
# This file is part of ScripTTY.
#
# ScripTTY is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ScripTTY is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with ScripTTY.  If not, see <http://www.gnu.org/licenses/>.
#
# = Documentation
# See the documentation for the RequestDispatcher for more information.

require 'scriptty/expect'
require 'thread'

module ScripTTY

  # Request dispatcher thread
  #
  # RequestDispatcher allows a single ScripTTY instance to maintain a
  # single, persistent connection to a remote host while multiple threads
  # perform requests via that connection.
  #
  # RequestDispatcher can be used, for example, to provide an HTTP interface to
  # functions of a screen-scraped terminal.
  class RequestDispatcher

    class RequestCancelled < StandardError; end

    def initialize
      # Graceful shutdown flag
      @finishing_lock = Mutex.new
      @finishing = false

      # Request queue
      @queue_lock = Mutex.new
      @queue = []

      # Hooks
      @hooks_lock = Mutex.new
      @hooks = {}
    end

    # Specify a block that will be called every time a new ScripTTY::Expect object is initialized.
    #
    # This can be used to specify a transcript_writer or to execute a login script.
    #
    # See the add_hook method for a descripton of how the arguments are interpreted.
    def after_init(how=nil, &block)
      add_hook(:after_init, how, &block)
    end

    # Add a block that will be called just before finally disconnecting, when the finish method is called.
    #
    # See the add_hook method for a descripton of how the arguments are interpreted.
    def before_finish(how=nil, &block)
      add_hook(:before_finish, how, &block)
    end

    # Add a block that will be called before each request is performed.
    #
    # See the add_hook method for a descripton of how the arguments are interpreted.
    def before_each_request(how=nil, &block)
      add_hook(:before_each_request, how, &block)
    end

    # Add a block that will be called before each request is performed.
    #
    # See the add_hook method for a descripton of how the arguments are interpreted.
    def after_each_request(how=nil, &block)
      add_hook(:after_each_request, how, &block)
    end

    # Start the dispatcher thread
    def start
      raise ArgumentError.new("Already started") if @thread
      @thread = Thread.new{ main }
      nil
    end

    # Stop the dispatcher thread
    def finish
      @finishing_lock.synchronize{ @finishing = true }
      @thread.join
      nil
    end

    # Queue a request and wait for it to complete
    def request(how=nil, &block)
      cv_mutex = Mutex.new
      cv = ConditionVariable.new

      # Build the request
      request = {:block => block, :cv_mutex => cv_mutex, :cv => cv }

      # Queue the request
      @queue_lock.synchronize{ @queue << request }

      # Wait for the request to complete
      cv_mutex.synchronize{ cv.wait(cv_mutex) }

      # Raise an exception if there was any.
      raise request[:exception] if request[:exception]

      # Return the result
      request[:result]
    end

    protected

      def main
        loop do
          break if finishing?
          wrap_in_exception_handler(
            :body => Proc.new {
              handle_one_request
            },
            :rescue => Proc.new { |exc|
              # Log & swallow exception
              show_exception(exc)
              close_expect rescue nil   # Ignore errors while closing the connection
              sleep 0.5   # Delay just a tiny bit to keep an exception loop from consuming all available resources.
            }
          )
        end
        execute_hooks(:before_finish)
      ensure
        close_expect

        # Clean up any remaining requests.
        while (request = dequeue)
          request[:exception] = RequestCancelled.new("main loop exited; request not executed")
          signal_request_done(request)
        end
      end

      def handle_one_request
        ensure_expect_alive
        until (request = dequeue)
          return if finishing?
          idle
        end

        # Run the before_each_request hooks.  If an exception is raised,
        # put the request back on the queue before re-raising the error.
        wrap_in_exception_handler(
          :body => Proc.new {
            execute_hooks(:before_each_request)
          },
          :rescue => Proc.new { |exc|
            requeue(request)
          },
          :reraise => true
        )

        # Execute the request
        success = false
        exception_caught = false
        begin
          wrap_in_exception_handler(
            :body => Proc.new {
              request[:result] = block_eval(request[:block_how], &request[:block])
              success = true
            },
            :rescue => Proc.new { |exc|
              show_exception(exc, "in request")
              request[:exception] = exc
              close_expect rescue nil
              exception_caught = true
            }
          )
        ensure
          signal_request_done(request)
          raise "RUBY BUG: No success and no exception caught: #{$ERROR_INFO.inspect}" unless success or exception_caught
        end

        # Execute the after_each_request hooks.
        execute_hooks(:after_each_request)
      end

      def dequeue
        @queue_lock.synchronize { @queue.shift }
      end

      def requeue(request)
        @queue_lock.synchronize { @queue.unshift(request) }
      end

      def ensure_expect_alive
        return if @expect
        @expect = construct_expect
        execute_hooks(:after_init)
        nil
      end

      def close_expect
        return unless @expect
        @expect.exit
      ensure
        @expect = nil
      end

      def finishing?
        @finishing_lock.synchronize { @finishing }
      end

      # Add a new hook of the specified type.
      #
      # The how argument determines how the block is called:
      # [:instance_eval]
      #   The block is passed to Expect#instance_eval
      # [:call]
      #   The block is called normally, and the Expect object is passed as its
      #   first argument.
      #
      # Hooks are executed in the order that they are set.
      def add_hook(type, how, &block)
        @hooks_lock.synchronize{
          @hooks[type] ||= []
          @hooks[type] << [how, block]
        }
        nil
      end

      def execute_hooks(type)
        @hooks_lock.synchronize{ (@hooks[type] || []).dup }.each do |how, block|
          block_eval(how, &block)
        end
        nil
      end

      def block_eval(how, &block)
        case how    # how specifies how the block will be called.
        when :instance_eval, nil
          @expect.instance_eval(&block)
        when :call
          block.call(@expect)
        else
          raise ArgumentError.new("Unsupported how: #{how.inspect}")
        end
      end

      def construct_expect
        ScripTTY::Expect.new
      end

      def idle
        @expect.sleep(0.1, :transcribe=>false)
      end

      def show_exception(exc, context=nil)
        output = ["Exception #{context || "in #{self}"}: #{exc} (#{exc.class.name})"]
        output += exc.backtrace.map { |line| " #{line}" }
        $stderr.puts output.join("\n")
      end

      def signal_request_done(request)
        request[:cv_mutex].synchronize { request[:cv].signal }
      end

      # XXX - Workaround for JRuby bug.
      #
      # Apparently, if we do this:
      #
      #   begin
      #     # some code here
      #   rescue Exception => exc
      #     # handle
      #   end
      #
      # Then other errors like SyntaxError and ArgumentError don't get caught
      # when we do our block-passing-over-threads magic.  However, if we
      # enumerate a bunch of exception classes, it seems to work.
      def wrap_in_exception_handler(options={})
        begin
          options[:body].call
        rescue Exception, ScriptError, SystemStackError, StandardError => exc
          options[:rescue].call(exc) if options[:rescue]
          raise if options[:reraise]
        end
      end
  end
end
