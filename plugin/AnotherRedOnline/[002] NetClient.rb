#===============================================================================
# Another Red Online — non-blocking TCP client
#
# Frame-polled to fit the RGSS/mkxp update loop. After connect, NEVER blocks the
# main thread: call #update once per frame, then drain messages with #poll.
# Framing: [len:uint32_be][json utf8] — identical to server/protocol.js.
#
# NOTE (mkxp-z build quirk, verified by socket probe): this build implements
# read_nonblock/write_nonblock/IO.select but NOT Socket#connect_nonblock. So the
# CONNECT is done with a blocking TCPSocket.new on a short-lived worker thread
# (MRI releases the GVL during the blocking connect → the game keeps rendering),
# and all subsequent I/O uses the non-blocking pump as before.
#===============================================================================
require 'socket'

module ARNet
  class NetClient
    attr_reader :state, :last_error

    # state: :connecting -> :connected -> :closed / :error
    def initialize(host, port = ARNet::DEFAULT_PORT)
      @host = host
      @port = port
      @rbuf = "".b            # incoming byte buffer (binary)
      @wbuf = "".b            # outgoing byte buffer (binary)
      @inbox = []             # parsed message hashes
      @last_error = nil
      @sock = nil
      @state = :connecting
      # Background blocking connect (no connect_nonblock in this build).
      @cmutex = Mutex.new
      @cdone  = false
      @csock  = nil
      @cerr   = nil
      @cthread = Thread.new do
        begin
          sk = TCPSocket.new(@host, @port)
          @cmutex.synchronize { @csock = sk; @cdone = true }
        rescue Exception => e
          @cmutex.synchronize { @cerr = e; @cdone = true }
        end
      end
    end

    def connected?; @state == :connected; end
    def closed?;    @state == :closed || @state == :error; end

    # Queue a message hash for sending (encoded immediately into wbuf).
    def send_msg(hash)
      return if closed?
      json = JSON.generate(hash)
      json = json.dup.force_encoding(Encoding::BINARY)
      raise "frame too large" if json.bytesize > ARNet::MAX_FRAME
      @wbuf << [json.bytesize].pack("N") << json
      nil
    end

    # Convenience: wrap a battle message for relay to the peer.
    def relay(data);  send_msg({ "t" => "relay", "data" => data }); end

    # Push the outgoing buffer to the socket RIGHT NOW instead of waiting for the
    # next #update. Critical for the lockstep: after a mid-turn switch pick the
    # owner immediately plays animations (recall/send-in, the foe's move) WITHOUT
    # calling #update, so without an explicit flush the "switch" message would sit
    # in @wbuf until the owner next hits an await (the end-of-round checksum) —
    # i.e. after all of the owner's animations finished. That is exactly what made
    # the peer's screen lag a whole step behind on U-turn / Baton Pass / Eject.
    def flush
      _pump_write if @state == :connected
    rescue SystemCallError => e
      _fail(e)
    end

    # Return and clear all received messages (array of hashes). Call after #update.
    def poll
      msgs = @inbox
      @inbox = []
      msgs
    end

    # Drive I/O. Call once per frame.
    def update
      case @state
      when :connecting then _drive_connect
      when :connected  then _pump_write; _pump_read
      end
    rescue SystemCallError => e
      _fail(e)
    end

    def close
      return if closed?
      begin; @cthread.kill if @cthread && @cthread.alive?; rescue; end
      begin; @sock.close if @sock; rescue; end
      @state = :closed
    end

    #--- internals -------------------------------------------------------------
    private

    # Poll the background connect thread; promote to :connected when it finishes.
    def _drive_connect
      done = sk = err = nil
      @cmutex.synchronize { done = @cdone; sk = @csock; err = @cerr }
      return unless done
      if err
        _fail(err)
      else
        @sock = sk
        # Disable Nagle: our frames are tiny and latency-sensitive (lockstep). We
        # explicitly #flush after each send, so we don't want the OS to sit on a
        # small write for ~40ms hoping to coalesce it.
        begin
          sk.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        rescue StandardError
        end
        @state = :connected
        _pump_write
      end
    end

    def _pump_write
      until @wbuf.empty?
        begin
          n = @sock.write_nonblock(@wbuf)
          @wbuf = (@wbuf.byteslice(n, @wbuf.bytesize - n) || "".b)
        rescue IO::WaitWritable
          break
        rescue EOFError, Errno::ECONNRESET, Errno::EPIPE => e
          _fail(e); break
        end
      end
    end

    def _pump_read
      loop do
        begin
          chunk = @sock.read_nonblock(4096)
          @rbuf << chunk
        rescue IO::WaitReadable
          break
        rescue EOFError
          close; break
        rescue Errno::ECONNRESET => e
          _fail(e); break
        end
      end
      _parse_frames
    end

    def _parse_frames
      loop do
        break if @rbuf.bytesize < 4
        len = @rbuf.byteslice(0, 4).unpack1("N")
        if len > ARNet::MAX_FRAME
          _fail(RuntimeError.new("oversize frame #{len}")); return
        end
        break if @rbuf.bytesize < 4 + len
        body = @rbuf.byteslice(4, len)
        @rbuf = (@rbuf.byteslice(4 + len, @rbuf.bytesize - (4 + len)) || "".b)
        begin
          @inbox << JSON.parse(body.force_encoding(Encoding::UTF_8))
        rescue JSON::ParserError
          # ignore malformed frame
        end
      end
    end

    def _fail(err)
      @last_error = err
      @state = :error
      begin; @sock.close; rescue; end
    end
  end
end
