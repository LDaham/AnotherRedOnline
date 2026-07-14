#===============================================================================
# Another Red Online — bundled stdlib shims
#
# This mkxp-z build ships MRI Ruby 3.1 but WITHOUT the pure-Ruby stdlib files,
# so `require 'json'` and `require 'securerandom'` fail with LoadError (verified
# in-game by the capability probe). The native extensions `digest` and `socket`
# DO load, so here we only need to provide a JSON codec + a SecureRandom shim.
#
# Loads first ([000]) so every later file can use the top-level `JSON` constant
# exactly like the real stdlib (JSON.generate / JSON.parse / JSON::ParserError).
#===============================================================================

# `digest` is a native ext in this build; pull it in so Digest::SHA256 exists.
begin; require 'digest';      rescue Exception; end
begin; require 'digest/sha2'; rescue Exception; end

#-------------------------------------------------------------------------------
# Shared log directory. Every ARNet debug/telemetry file (battle-event dumps,
# chess-clock trace, exception log, bundle self-test) goes under ONE folder in
# the game directory instead of scattering *.log / *.txt into the root.
# ARNet.log_path(name) creates the folder on demand and returns the full path;
# on any failure (e.g. mkxp filesystem quirk) it falls back to the bare filename
# so logging can never crash the game. Defined here in [000] so all later files
# (and this file's own self-test below) can use it.
#-------------------------------------------------------------------------------
module ARNet
  LOG_DIR = "ARNet_Logs".freeze

  def self.log_path(filename)
    begin
      Dir.mkdir(LOG_DIR) unless Dir.exist?(LOG_DIR)
      return File.join(LOG_DIR, filename) if Dir.exist?(LOG_DIR)
    rescue Exception
    end
    filename
  end
end

#-------------------------------------------------------------------------------
# Minimal, dependency-free JSON (RFC 8259 subset sufficient for our protocol).
#-------------------------------------------------------------------------------
unless defined?(JSON)
  module JSON
    class ParserError    < StandardError; end
    class GeneratorError < StandardError; end

    # --- generate ----------------------------------------------------------
    def self.generate(obj)
      buf = +""
      _enc(obj, buf)
      buf
    end
    class << self; alias_method :dump, :generate; end

    def self._enc(o, b)
      case o
      when nil        then b << "null"
      when true       then b << "true"
      when false      then b << "false"
      when Integer    then b << o.to_s
      when Float
        raise GeneratorError, "non-finite float" unless o.finite?
        b << o.to_s
      when String     then _enc_str(o, b)
      when Symbol     then _enc_str(o.to_s, b)
      when Array
        b << "["
        o.each_with_index { |v, i| b << "," if i > 0; _enc(v, b) }
        b << "]"
      when Hash
        b << "{"
        first = true
        o.each do |k, v|
          b << "," unless first
          first = false
          _enc_str(k.to_s, b)
          b << ":"
          _enc(v, b)
        end
        b << "}"
      else
        _enc_str(o.to_s, b)
      end
    end

    # Raw UTF-8 bytes pass through verbatim (valid in JSON strings); only the
    # mandatory escapes + C0 control chars are escaped. Works on UTF-8 or
    # BINARY strings (BINARY high bytes iterate one-per-char and are preserved).
    def self._enc_str(s, b)
      b << '"'
      s.each_char do |ch|
        case ch
        when '"'  then b << '\\"'
        when "\\" then b << "\\\\"
        when "\n" then b << "\\n"
        when "\t" then b << "\\t"
        when "\r" then b << "\\r"
        when "\b" then b << "\\b"
        when "\f" then b << "\\f"
        else
          c = ch.ord
          if c < 0x20
            b << format("\\u%04x", c)
          else
            b << ch
          end
        end
      end
      b << '"'
    end

    # --- parse -------------------------------------------------------------
    def self.parse(str)
      s = str.to_s
      s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
      p = Parser.new(s)
      v = p.parse_value
      p.skip_ws
      raise ParserError, "trailing characters" unless p.eos?
      v
    end

    class Parser
      def initialize(s); @s = s; @i = 0; @n = s.length; end
      def eos?; @i >= @n; end

      def skip_ws
        @i += 1 while @i < @n && (c = @s[@i]) && (c == " " || c == "\t" || c == "\n" || c == "\r")
      end

      def parse_value
        skip_ws
        raise ParserError, "unexpected end" if @i >= @n
        case @s[@i]
        when '{' then parse_obj
        when '[' then parse_arr
        when '"' then parse_str
        when 't' then lit("true",  true)
        when 'f' then lit("false", false)
        when 'n' then lit("null",  nil)
        else          parse_num
        end
      end

      def lit(word, val)
        raise ParserError, "invalid token" unless @s[@i, word.length] == word
        @i += word.length
        val
      end

      def parse_obj
        @i += 1
        h = {}
        skip_ws
        if @s[@i] == '}'; @i += 1; return h; end
        loop do
          skip_ws
          raise ParserError, "expected string key" unless @s[@i] == '"'
          k = parse_str
          skip_ws
          raise ParserError, "expected ':'" unless @s[@i] == ':'
          @i += 1
          h[k] = parse_value
          skip_ws
          case @s[@i]
          when ','; @i += 1
          when '}'; @i += 1; break
          else raise ParserError, "expected ',' or '}'"
          end
        end
        h
      end

      def parse_arr
        @i += 1
        a = []
        skip_ws
        if @s[@i] == ']'; @i += 1; return a; end
        loop do
          a << parse_value
          skip_ws
          case @s[@i]
          when ','; @i += 1
          when ']'; @i += 1; break
          else raise ParserError, "expected ',' or ']'"
          end
        end
        a
      end

      def parse_str
        @i += 1
        out = +""
        while @i < @n
          c = @s[@i]
          if c == '"'
            @i += 1
            return out
          elsif c == "\\"
            @i += 1
            e = @s[@i]
            case e
            when '"'  then out << '"'
            when "\\" then out << "\\"
            when '/'  then out << '/'
            when 'n'  then out << "\n"
            when 't'  then out << "\t"
            when 'r'  then out << "\r"
            when 'b'  then out << "\b"
            when 'f'  then out << "\f"
            when 'u'
              cp = _hex4
              if cp >= 0xD800 && cp <= 0xDBFF && @s[@i + 1] == "\\" && @s[@i + 2] == 'u'
                @i += 2
                lo = _hex4
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
              end
              out << [cp].pack("U")
            else
              raise ParserError, "invalid escape"
            end
            @i += 1
          else
            out << c
            @i += 1
          end
        end
        raise ParserError, "unterminated string"
      end

      # reads 4 hex digits following a \u (the 'u' is at @i); leaves @i on last digit
      def _hex4
        hex = @s[@i + 1, 4]
        raise ParserError, "bad \\u escape" unless hex && hex.length == 4
        @i += 4
        hex.to_i(16)
      end

      def parse_num
        start = @i
        @i += 1 while @i < @n && "+-0123456789.eE".include?(@s[@i])
        tok = @s[start...@i]
        raise ParserError, "invalid number" if tok.empty?
        begin
          (tok =~ /[.eE]/) ? Float(tok) : Integer(tok)
        rescue ArgumentError
          raise ParserError, "invalid number '#{tok}'"
        end
      end
    end
  end
end

#-------------------------------------------------------------------------------
# SecureRandom shim — only hex(n) is used (nonce generation). Not used for any
# cryptographic secret; just needs to be unpredictable per peer for fair seed
# derivation. Backed by Random (system-seeded in MRI).
#-------------------------------------------------------------------------------
unless defined?(SecureRandom)
  module SecureRandom
    def self.random_bytes(n = 16)
      Random.new.bytes(n)
    rescue Exception
      (0...n).map { rand(256) }.pack("C*")
    end

    def self.hex(n = 16)
      random_bytes(n).unpack1("H*")
    end

    def self.uuid
      b = random_bytes(16).bytes
      b[6] = (b[6] & 0x0f) | 0x40
      b[8] = (b[8] & 0x3f) | 0x80
      h = b.map { |x| format("%02x", x) }.join
      "#{h[0,8]}-#{h[8,4]}-#{h[12,4]}-#{h[16,4]}-#{h[20,12]}"
    end
  end
end

#-------------------------------------------------------------------------------
# One-time load self-test. Silent on success; on failure writes arnet_bundle.txt
# so a codec bug is caught here (before the battle) instead of being mistaken for
# a netcode desync. Never raises — a broken test must not take down the game.
#-------------------------------------------------------------------------------
begin
  _fixture = {
    "t" => "relay",
    "n" => 50,
    "f" => 1.5,
    "b" => true,
    "z" => nil,
    "arr" => [1, 2, "셋", { "k" => "v" }],
    "name" => "레드\t\"Red\"\\x",
    "ko" => "한글 테스트 ✓"
  }
  _round = JSON.parse(JSON.generate(_fixture))
  _fails = []
  _fails << "t"    unless _round["t"] == "relay"
  _fails << "n"    unless _round["n"] == 50
  _fails << "f"    unless _round["f"] == 1.5
  _fails << "b"    unless _round["b"] == true
  _fails << "z"    unless _round["z"].nil?
  _fails << "arr"  unless _round["arr"] == [1, 2, "셋", { "k" => "v" }]
  _fails << "name" unless _round["name"] == "레드\t\"Red\"\\x"
  _fails << "ko"   unless _round["ko"] == "한글 테스트 ✓"
  _fails << "digest" unless Digest::SHA256.hexdigest("abc")[0, 8] == "ba7816bf"
  _fails << "securerandom" unless SecureRandom.hex(8).length == 16
  unless _fails.empty?
    begin
      File.open(ARNet.log_path("arnet_bundle.txt"), "wb") do |f|
        f.write("BUNDLE_SELFTEST_FAIL fields=#{_fails.join(',')}\n")
        f.write("generate=#{JSON.generate(_fixture)}\n")
      end
    rescue Exception; end
  end
rescue Exception => _e
  begin
    File.open(ARNet.log_path("arnet_bundle.txt"), "wb") { |f| f.write("BUNDLE_SELFTEST_CRASH #{_e.class}: #{_e.message}\n") }
  rescue Exception; end
end
