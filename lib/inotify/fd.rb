require "rubygems"
require "ffi"
require "inotify/event"
require "inotify/namespace"
require "inotify/stringpipeio"

class Inotify::FD
  include Enumerable

  module CInotify
    extend FFI::Library
    ffi_lib FFI::Library::LIBC

    attach_function :inotify_init, [], :int
    attach_function :inotify_init1, [:int], :int
    attach_function :inotify_add_watch, [:int, :string, :uint32], :int

    # So we can read and poll inotify from jruby.
    attach_function :read, [:int, :pointer, :size_t], :int

    # Poll is pretty crappy, but it's better than nothing.
    attach_function :poll, [:pointer, :int, :int], :int
  end

  INOTIFY_CLOEXEC = 02000000
  INOTIFY_NONBLOCK = 04000

  WATCH_BITS = {
    :access => 1 << 0,
    :modify => 1 << 1,
    :attrib => 1 << 2,
    :close_write => 1 << 3,
    :close_nowrite => 1 << 4,
    :open => 1 << 5,
    :moved_from => 1 << 6,
    :moved_to => 1 << 7,
    :create => 1 << 8,
    :delete => 1 << 9,
    :delete_self => 1 << 10,
    :move_self => 1 << 11,

    # Shortcuts
    :close => (1 << 3) | (1 << 4),
    :move => (1 << 6) | (1 << 7) | (1 << 11),
    :delete => (1 << 9) | (1 << 10),
  }

  attr_reader :fd

  public
  def initialize
    @watches = {}
    @buffer = Inotify::StringPipeIO.new

    @fd = CInotify.inotify_init1(INOTIFY_NONBLOCK)

    if java?
      @io = nil
    else
      @io = IO.for_fd(@fd)
    end
  end

  public
  def java?
    return RUBY_PLATFORM == "java"
  end

  # Add a watch.
  # - path is a string file path
  # - what_to_watch is any of the valid WATCH_BITS keys
  #
  # Example:
  #   watch("/tmp", :craete, :delete)
  public
  def watch(path, *what_to_watch)
    mask = what_to_watch.inject(0) { |m, val| m |= WATCH_BITS[val] }
    watch_descriptor = CInotify.inotify_add_watch(@fd, path, mask)
    #puts "watch #{path} => #{watch_descriptor}"

    if watch_descriptor == -1
      raise "inotify_add_watch(#{@fd}, #{path}, #{mask}) failed. #{$?}"
    end
    @watches[watch_descriptor] = {
      :path => path,
      :partial => nil
    }
  end

  private
  def normal_read(timeout=nil)
    loop do
      begin
        data = @io.sysread(4096)
        @buffer.write(data)
      rescue Errno::EAGAIN
        # No data left to read, moveon.
        break
      end
    end
    return nil
  end # def normal_read

  private
  def jruby_read(timeout=nil)
    @jruby_read_buffer = FFI::MemoryPointer.new(:char, 4096)

    # TODO(sissel): Block with select.
    # Will have to use FFI to call select, too.

    # We ahve to call libc's read(2) because JRuby/Java can't trivially
    # be told about existing file descriptors.
    loop do
      bytes = CInotify.read(@fd, @jruby_read_buffer, 4096)

      # read(2) returns -1 on error, which we expect to be EAGAIN, but...
      # TODO(sissel): maybe we should check errno properly...
      # Then again, errno isn't threadsafe, so we'd have to wrap this
      # in a critical block? Fun times
      break if bytes == -1

      @buffer.write(@jruby_read_buffer.get_bytes(0, bytes))
    end
    return nil
  end # def jruby_read
    
  # Make any necessary corrections to the event
  private
  def prepare(event)
    watchpath = @watches[event[:wd]][:path]
    if event.name == nil
      # Some events don't have the name at all, so add our own.
      event.name = watchpath
    else
      # Event paths are relative to the watch. Prefix to make the full path.
      event.name = File.join(watchpath, event.name)
    end

    return event
  end # def prepare

  # Get one inotify event.
  #
  # If timeout is not given, this call blocks.
  # If a timeout occurs and no event was read, nil is returned.
  #
  # Returns nil on timeout or an Inotify::Event on success.
  public
  def get(timeout=nil)
    # This big 'loop' is to support pop { |event| ... } shipping each available event.
    # It's not very rubyish (we should probably use Enumerable and such.
    if java?
      jruby_read(timeout)
    else
      normal_read(timeout)
    end

    # Recover any previous partial event.
    if @partial
      event = @partial.from_stringpipeio(@buffer)
    else
      event = Inotify::Event.from_stringpipeio(@buffer)
      return nil if event == nil
    end

    if event.partial?
      @partial = event
      return nil
    end
    @partial = nil

    return prepare(event)
  end # def get

  # For Enumerable support
  # 
  # Yields one Inotify::Event per iteration. If there are no more events
  # at the this time, then this method will end.
  public
  def each(&block)
    loop do
      event = get
      break if event == nil
      yield prepare(event)
    end # loop
  end # def each

  # Subscribe to inotify events for this instance.
  # 
  # If you are running in EventMachine, this will set up a 
  # subscription that behaves sanely in EventMachine
  #
  # If you are not running in EventMachine, this method
  # blocks forever, invoking the given block for each event.
  # Further, if you are not using EventMachine, you should
  # not pass a handler, only a block, like this:
  #
  #   fd.subscribe do |event|
  #     puts event
  #   end
  public
  def subscribe(handler=nil, &block)
    if defined?(EventMachine) && EventMachine.reactor_running?
      require "inotify/emhandler"
      handler = Inotify::EMHandler if handler == nil
      EventMachine::watch(@fd, handler, self, block)
    else
      loop do
        if java?
          # No way to select on FFI-derived file descriptors yet,
          # when I grab poll(2) via FFI, this sleep will become
          # a poll or sleep invocation.
          sleep(1)
        else
          IO.select([@io], nil, nil, nil)
        end
        each(&block)
      end
    end
  end
end # class Inotify::FD
