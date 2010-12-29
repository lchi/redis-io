require File.expand_path(File.dirname(__FILE__) + "/redis")
require "shellwords"

module Interactive

  # Create and find actions have race conditions, but I don't
  # really care about them right now...
  class Session

    # Create new instance.
    def self.create(namespace)
      raise "Already exists" if redis.zscore("sessions", namespace)
      touch(namespace)
      new(namespace)
    end

    # Return instance if namespace exists in sorted set.
    def self.find(namespace)
      if timestamp = redis.zscore("sessions", namespace)
        if Time.now.to_i - timestamp.to_i < 3600
          touch(namespace)
          new(namespace)
        end
      end
    end

    # This should only be created through #new or #create
    private_class_method :new

    attr :namespace

    def initialize(namespace)
      @namespace = namespace
    end

    def run(line)
      _run(line)
    rescue => error
      format_reply(ErrorReply.new("ERR " + error.message))
    end

  private

    def self.touch(namespace)
      redis.zadd("sessions", Time.now.to_i, namespace)
    end

    def register(arguments)
      # TODO: Only store keys that receive writes.
      keys = ::Interactive.keys(arguments)
      redis.pipelined do
        keys.each do |key|
          redis.sadd("session:#{namespace}:keys", key)
        end
      end

      # Command counter, not yet used
      redis.incr("session:#{namespace}:commands")
    end

    def _run(line)
      begin
        arguments = Shellwords.shellwords(line)
      rescue => error
        raise error.message.split(":").first
      end

      if arguments.empty?
        raise "No command"
      end

      if arguments.size > 100 || arguments.any? { |arg| arg.size > 100 }
        raise "Web-based interface is limited"
      end

      namespaced = ::Interactive.namespace(namespace, arguments)
      if namespaced.empty?
        raise "Unknown or disabled command '%s'" % arguments.first
      end

      # Register the call
      register(arguments)

      # Make the call
      reply = ::Interactive.redis.client.call(*namespaced)

      # Strip namespace for KEYS
      if arguments.first.downcase == "keys"
        reply.map! { |key| key[/^\w+:(.*)$/,1] }
      end

      format_reply(reply)
    end

    def format_reply(reply, prefix = "")
      case reply
      when LineReply
        reply.to_s + "\n"
      when Fixnum
        "(integer) " + reply.to_s + "\n"
      when String
        reply.inspect + "\n"
      when NilClass
        "(nil)\n"
      when Array
        if reply.empty?
          "(empty list or set)\n"
        else
          out = ""
          index_size = reply.size.to_s.size
          reply.each_with_index do |element, index|
            out << prefix if index > 0
            out << "%#{index_size}d) " % (index + 1)
            out << format_reply(element, prefix + (" " * (index_size + 2)))
          end
          out
        end
      else
        raise "Don't know how to format #{reply.inspect}"
      end
    end
  end
end
