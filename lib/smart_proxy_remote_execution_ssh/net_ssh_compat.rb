module Proxy::RemoteExecution
  module NetSSHCompat
    class Buffer
      # exposes the raw content of the buffer
      attr_reader :content

      # the current position of the pointer in the buffer
      attr_accessor :position

      # Creates a new buffer, initialized to the given content. The position
      # is initialized to the beginning of the buffer.
      def initialize(content = +'')
        @content = content.to_s
        @position = 0
      end

      # Returns the length of the buffer's content.
      def length
        @content.length
      end

      # Returns the number of bytes available to be read (e.g., how many bytes
      # remain between the current position and the end of the buffer).
      def available
        length - position
      end

      # Returns a copy of the buffer's content.
      def to_s
        (@content || "").dup
      end

      # Returns +true+ if the buffer contains no data (e.g., it is of zero length).
      def empty?
        @content.empty?
      end

      # Resets the pointer to the start of the buffer. Subsequent reads will
      # begin at position 0.
      def reset!
        @position = 0
      end

      # Returns true if the pointer is at the end of the buffer. Subsequent
      # reads will return nil, in this case.
      def eof?
        @position >= length
      end

      # Resets the buffer, making it empty. Also, resets the read position to
      # 0.
      def clear!
        @content = +''
        @position = 0
      end

      # Consumes n bytes from the buffer, where n is the current position
      # unless otherwise specified. This is useful for removing data from the
      # buffer that has previously been read, when you are expecting more data
      # to be appended. It helps to keep the size of buffers down when they
      # would otherwise tend to grow without bound.
      #
      # Returns the buffer object itself.
      def consume!(count = position)
        if count >= length
          # OPTIMIZE: a fairly common case
          clear!
        elsif count.positive?
          @content = @content[count..-1] || +''
          @position -= count
          @position = 0 if @position.negative?
        end
        self
      end

      # Appends the given text to the end of the buffer. Does not alter the
      # read position. Returns the buffer object itself.
      def append(text)
        @content << text
        self
      end

      # Reads and returns the next +count+ bytes from the buffer, starting from
      # the read position. If +count+ is +nil+, this will return all remaining
      # text in the buffer. This method will increment the pointer.
      def read(count = nil)
        count ||= length
        count = length - @position if @position + count > length
        @position += count
        @content[@position - count, count]
      end

      # Writes the given data literally into the string. Does not alter the
      # read position. Returns the buffer object.
      def write(*data)
        data.each { |datum| @content << datum.dup.force_encoding('BINARY') }
        self
      end
    end

    module BufferedIO
      # This module is used to extend sockets and other IO objects, to allow
      # them to be buffered for both read and write. This abstraction makes it
      # quite easy to write a select-based event loop
      # (see Net::SSH::Connection::Session#listen_to).
      #
      # The general idea is that instead of calling #read directly on an IO that
      # has been extended with this module, you call #fill (to add pending input
      # to the internal read buffer), and then #read_available (to read from that
      # buffer). Likewise, you don't call #write directly, you call #enqueue to
      # add data to the write buffer, and then #send_pending or #wait_for_pending_sends
      # to actually send the data across the wire.
      #
      # In this way you can easily use the object as an argument to IO.select,
      # calling #fill when it is available for read, or #send_pending when it is
      # available for write, and then call #enqueue and #read_available during
      # the idle times.
      #
      #   socket = TCPSocket.new(address, port)
      #   socket.extend(Net::SSH::BufferedIo)
      #
      #   ssh.listen_to(socket)
      #
      #   ssh.loop do
      #     if socket.available > 0
      #       puts socket.read_available
      #       socket.enqueue("response\n")
      #     end
      #   end
      #
      # Note that this module must be used to extend an instance, and should not
      # be included in a class. If you do want to use it via an include, then you
      # must make sure to invoke the private #initialize_buffered_io method in
      # your class' #initialize method:
      #
      #   class Foo < IO
      #     include Net::SSH::BufferedIo
      #
      #     def initialize
      #       initialize_buffered_io
      #       # ...
      #     end
      #   end

      # Tries to read up to +n+ bytes of data from the remote end, and appends
      # the data to the input buffer. It returns the number of bytes read, or 0
      # if no data was available to be read.
      def fill(count = 8192)
        input.consume!
        data = recv(count)
        input.append(data)
        return data.length
      rescue EOFError => e
        @input_errors << e
        return 0
      end

      # Read up to +length+ bytes from the input buffer. If +length+ is nil,
      # all available data is read from the buffer. (See #available.)
      def read_available(length = nil)
        input.read(length || available)
      end

      # Returns the number of bytes available to be read from the input buffer.
      # (See #read_available.)
      def available
        input.available
      end

      # Enqueues data in the output buffer, to be written when #send_pending
      # is called. Note that the data is _not_ sent immediately by this method!
      def enqueue(data)
        output.append(data)
      end

      # Sends as much of the pending output as possible. Returns +true+ if any
      # data was sent, and +false+ otherwise.
      def send_pending
        if output.length.positive?
          sent = send(output.to_s, 0)
          output.consume!(sent)
          return sent.positive?
        else
          return false
        end
      end

      # Calls #send_pending repeatedly, if necessary, blocking until the output
      # buffer is empty.
      def wait_for_pending_sends
        send_pending
        while output.length.positive?
          result = IO.select(nil, [self]) || next
          next unless result[1].any?

          send_pending
        end
      end

      private

      #--
      # Can't use attr_reader here (after +private+) without incurring the
      # wrath of "ruby -w". We hates it.
      #++

      def input
        @input
      end

      def output
        @output
      end

      # Initializes the intput and output buffers for this object. This method
      # is called automatically when the module is mixed into an object via
      # Object#extend (see Net::SSH::BufferedIo.extended), but must be called
      # explicitly in the +initialize+ method of any class that uses
      # Module#include to add this module.
      def initialize_buffered_io
        @input = Buffer.new
        @input_errors = []
        @output = Buffer.new
        @output_errors = []
      end
    end
  end
end
