#===============================================================================
# Another Red Online — mod integrity hash (anti-tamper step 2)
#
# Computes a short SHA256 fingerprint of OUR mod's own script SOURCE — the
# AnotherRedOnline plugin baked into Data/PluginScripts.rxdata. Two peers running
# the same release have byte-identical source for these scripts, so the hash
# matches; editing any of our baked scripts changes it. Peers exchange this in
# the handshake ([003]) and refuse to battle on mismatch.
#
# WHY only our mod's source (not base game files):
#   The release ships only our baked scripts + assets on top of a base game the
#   player already has. Base files (Scripts.rxdata, moves.dat, ...) can legitimately
#   differ per platform/version (e.g. a mobile build), so hashing them would block
#   honest cross-platform matches. Our own plugin source, by contrast, is identical
#   everywhere for a given release. Base-data tampering that actually changes battle
#   math is caught by the lockstep checksum ([008]/[009]) — the real backstop; this
#   hash is the fast, friendly pre-battle guard against MOD tampering.
#
# We hash the DECOMPRESSED source, not the stored deflate bytes, so the result is
# a pure function of the source text (immune to zlib/compression nondeterminism).
#
# Threat model (integrity-anticheat memory): self-reported ⇒ a determined reverser
# can fake it. Its job is catching casual tampering / version drift up front.
#
# Fail-open: any read/parse failure ⇒ #hash returns nil. A nil on either side is
# treated as "unknown" and does NOT block the match — never punish an honest
# player for an IO/format hiccup; the lockstep checksum still guards.
#===============================================================================
begin; require 'zlib'; rescue Exception; end   # native ext (the engine uses it to load these very scripts)

module ARNet
  module Build
    module_function

    # Must match plugin_baker.py PLUGIN_NAME (the baked top-level element name).
    PLUGIN_NAME = "Another Red Online"
    RXDATA_REL  = "Data/PluginScripts.rxdata"

    # Locate the baked plugin file (CWD-relative, with a Dir.pwd fallback).
    def rxdata_path
      cands = [RXDATA_REL]
      begin; cands << File.join(Dir.pwd, RXDATA_REL); rescue Exception; end
      cands.find { |p| (File.file?(p) rescue false) }
    end

    # 16-hex fingerprint of our mod's script source, or nil (fail-open).
    #   rxdata = Marshal[ [name, meta, [[filename, Zlib.deflate(source)], ...]], ... ]
    def compute
      path = rxdata_path
      return nil unless path
      plugins = Marshal.load(File.binread(path))
      ours = plugins.find { |el| el.is_a?(Array) && el[0].to_s == PLUGIN_NAME }
      return nil unless ours && ours[2].is_a?(Array)
      entries = ours[2].map { |fn, deflated| [fn.to_s, Zlib.inflate(deflated)] }
      entries.sort_by! { |fn, _| fn }          # stable order regardless of bake order
      dig = Digest::SHA256.new
      entries.each do |fn, src|
        dig.update(fn); dig.update("\0")
        dig.update(src); dig.update("\0")
      end
      dig.hexdigest[0, 16]
    rescue Exception
      nil
    end

    # Computed once and cached. nil => could not read/parse (fail-open handshake).
    def hash
      return @hash if defined?(@hash)
      @hash = compute
    end

    # For debugging: per-script source sizes (not sent over the wire).
    def report
      path = rxdata_path
      return ["rxdata not found"] unless path
      plugins = Marshal.load(File.binread(path)) rescue (return ["marshal load failed"])
      ours = plugins.find { |el| el.is_a?(Array) && el[0].to_s == PLUGIN_NAME }
      return ["plugin '#{PLUGIN_NAME}' not baked"] unless ours && ours[2].is_a?(Array)
      ours[2].map do |fn, defl|
        begin; "#{fn} => #{Zlib.inflate(defl).bytesize} bytes"; rescue Exception; "#{fn} => ERR"; end
      end
    end
  end
end
