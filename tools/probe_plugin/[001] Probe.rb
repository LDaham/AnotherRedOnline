# ARNet socket probe v3. Writes arnet_sock.txt (mkxp write dir = %APPDATA%\...).
# Goal: this build has TCPSocket.new (blocking) but NO Socket#connect_nonblock.
# Determine which BLOCKING socket methods exist so we can build a thread-based
# blocking-IO client. Also does a real hello/hello_ok round-trip vs the relay.
lines = []
HOST = "217.142.253.174"
PORT = 8787
begin
  add = proc { |k, v| lines << "#{k}=#{v}" }
  require 'socket'

  add.call("IO_select", (IO.respond_to?(:select) ? true : false))
  add.call("def_IO_WaitReadable", (defined?(IO::WaitReadable) ? true : false))
  add.call("def_Errno_EAGAIN", (defined?(Errno::EAGAIN) ? true : false))

  sock = nil
  begin
    sock = TCPSocket.new(HOST, PORT)
    add.call("tcpsocket_new", "ok")
  rescue Exception => e
    add.call("tcpsocket_new", "FAIL:#{e.class}:#{e.message}")
  end

  if sock
    %w[connect_nonblock read_nonblock write_nonblock recv recv_nonblock
       readpartial read write send sysread syswrite gets
       puts flush setsockopt close].each do |m|
      r = begin; sock.respond_to?(m) ? true : false; rescue Exception; "err"; end
      add.call("resp_#{m}", r)
    end

    # Real round-trip: send hello frame, read hello_ok. Proves blocking write+read.
    begin
      json = '{"t":"hello","proto":1,"name":"probe"}'
      jb = json.dup.force_encoding(Encoding::BINARY)
      frame = [jb.bytesize].pack("N") + jb
      sock.write(frame)
      add.call("write_hello", "ok(#{frame.bytesize}b)")
      hdr = sock.read(4)
      if hdr && hdr.bytesize == 4
        len = hdr.unpack1("N")
        add.call("reply_len", len)
        body = sock.read(len)
        bs = body ? body.bytesize : 0
        add.call("reply_body_bytes", bs)
        txt = body ? body.force_encoding(Encoding::UTF_8) : ""
        add.call("reply_has_hello_ok", (txt.include?("hello_ok") ? true : false))
        add.call("reply_text", txt.gsub("\n", " "))
      else
        add.call("reply_len", "short_or_nil:#{hdr.inspect}")
      end
    rescue Exception => e
      add.call("roundtrip", "FAIL:#{e.class}:#{e.message}")
    end
    begin; sock.close; rescue Exception; end
  end
rescue Exception => e
  lines << "PROBE_OUTER_ERROR=#{e.class}:#{e.message}"
ensure
  begin
    payload = "ARNET_SOCK\n" + lines.join("\n") + "\n"
    File.open("arnet_sock.txt", "wb") { |f| f.write(payload) }
  rescue Exception
  end
end
