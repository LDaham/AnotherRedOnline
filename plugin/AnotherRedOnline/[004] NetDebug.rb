#===============================================================================
# Another Red Online — in-game debug self-test
#
# Run from the mkxp/Essentials debug console or a debug event:
#   ARNet.selftest("127.0.0.1")                  # host: creates a room, prints code
#   ARNet.selftest("127.0.0.1", room: "ABCDE")   # guest: join that room code
#
# Connects, does hello + code-room matchmaking + bhello handshake, prints side/seed,
# then exchanges a couple of relay messages. Non-blocking; pumps for ~10s.
#===============================================================================
module ARNet
  def self.selftest(host = ARNet::DEFAULT_HOST, port: ARNet::DEFAULT_PORT, room: nil, format: ARNet::FORMAT_SINGLE3)
    s = ARNet::Session.new(host, port, name: "SelfTest")
    s.on_room_created = proc { |code| _log("room created: #{code}  (have peer join it)") }
    s.on_ready = proc { |side, seed| _log("HANDSHAKE OK  side=#{side} seed=#{seed}") }
    s.on_peer_msg = proc { |d| _log("peer battle msg: #{d.inspect}") }
    s.on_peer_left = proc { |r| _log("peer left: #{r}") }

    started = false
    sent_probe = false
    frames = 0
    max_frames = 60 * 15   # ~15s at 60fps

    loop do
      s.update
      frames += 1

      if s.phase == :idle && !started
        started = true
        if room
          _log("joining room #{room} ..."); s.join_room(room)
        else
          _log("hosting room (#{format}) ... share the code with your peer"); s.create_room(format)
        end
      end

      if s.phase == :ready && !sent_probe
        sent_probe = true
        s.send_battle({ "t" => "probe", "hello" => "from side #{s.side}" })
      end

      break if s.phase == :error || s.phase == :closed
      break if frames > max_frames
      _sleep_frame
    end

    _log("final phase=#{s.phase} error=#{s.error.inspect}")
    s.close
  end

  # Full end-to-end online battle (Phase 4). Run on two instances:
  #   host:  ARNet.online_battle("SERVER_IP")               # prints room code
  #   guest: ARNet.online_battle("SERVER_IP", room: "ABCDE")
  # Uses $player.party as the team. For selection formats, auto-picks the first N.
  def self.online_battle(host = ARNet::DEFAULT_HOST, port: ARNet::DEFAULT_PORT, room: nil, format: ARNet::FORMAT_SINGLE3)
    s = ARNet::Session.new(host, port, name: ($player ? $player.name : "Trainer"))
    pending_info = nil

    s.on_room_created = proc { |code| _log("ROOM CODE: #{code}  (have your opponent join it)") }
    s.on_ready = proc do |side, seed|
      _log("handshake ok: side=#{side} seed=#{seed}; sending team...")
      s.submit_team(ARNet::Team.party_to_data($player.party))
    end
    s.on_peer_team = proc do |peer_data|
      _log("opponent team received (#{peer_data.length} mons)")
      if ARNet.needs_selection?(format)
        n = ARNet.picks_for(format)
        s.submit_selection((0...n).to_a)   # auto-pick first N; real UI later
      end
    end
    s.on_battle_ready = proc { |info| pending_info = info }
    s.on_peer_left = proc { |r| _log("peer left: #{r}") }

    started = false
    loop do
      s.update
      if s.phase == :idle && !started
        started = true
        room ? (s.join_room(room); _log("joining #{room}...")) : s.create_room(format)
      end
      if pending_info
        _log("battle_ready -> launching online battle")
        outcome, reason = ARNet.start_online_battle(s, pending_info)
        _log("battle ended: outcome=#{outcome} reason=#{reason.inspect}")
        break
      end
      break if s.phase == :error || s.phase == :closed
      _sleep_frame
    end
    _log("final phase=#{s.phase} error=#{s.error.inspect}")
    s.close
  end

  # Team serialization round-trip self-test (Phase 3). Run in-game:
  #   ARNet.team_selftest            # uses $player.party
  # Serializes each party mon -> JSON -> back, applies Lv50/IV31 normalization,
  # validates, and reports field-level diffs + that normalization took effect.
  def self.team_selftest(party = nil)
    party ||= ($player && $player.party) || []
    if party.empty?
      _log("team_selftest: no party to test"); return
    end
    rs = ARNet.default_ruleset
    data = ARNet::Team.party_to_data(party)
    json = JSON.generate(data)
    _log("serialized #{data.length} mons, #{json.bytesize} bytes JSON")

    parsed = JSON.parse(json)
    ok, result = ARNet::Team.data_to_party(parsed, rs)
    unless ok
      _log("VALIDATION FAILED: #{result}"); return
    end

    result.each_with_index do |pk, i|
      src = party[i]
      diffs = []
      diffs << "species #{src.species}->#{pk.species}" if src.species != pk.species
      diffs << "ability #{src.ability_id}->#{pk.ability_id}" if src.ability_id != pk.ability_id
      diffs << "nature #{src.nature_id}->#{pk.nature_id}" if src.nature_id != pk.nature_id
      diffs << "item #{src.item_id}->#{pk.item_id}" if src.item_id != pk.item_id
      src_moves = src.moves.map { |m| m.id }
      pk_moves  = pk.moves.map { |m| m.id }
      diffs << "moves #{src_moves}->#{pk_moves}" if src_moves != pk_moves
      lvl_ok = (pk.level == rs["level_cap"])
      iv_ok  = ARNet::Team.stat_ids.all? { |s| pk.iv[s] == rs["iv_flat"] }
      _log("#{src.name}: level=#{pk.level}(#{lvl_ok ? 'OK' : 'BAD'}) " \
           "iv6v=#{iv_ok ? 'OK' : 'BAD'} " \
           "#{diffs.empty? ? 'fields match' : 'DIFF ' + diffs.join(', ')}")
    end
    _log("team_selftest done (level forced to #{rs["level_cap"]}, IV forced to #{rs["iv_flat"]})")
  end

  # Deterministic PRNG self-test (Phase 4). Run in-game: ARNet.prng_selftest
  def self.prng_selftest
    a = ARNet::PRNG.new(123456789)
    b = ARNet::PRNG.new(123456789)
    sa = Array.new(1000) { a.rand(100) }
    sb = Array.new(1000) { b.rand(100) }
    _log("same-seed identical: #{sa == sb}")
    c = ARNet::PRNG.new(987654321)
    sc = Array.new(1000) { c.rand(100) }
    _log("diff-seed differs: #{sa != sc}")
    d = ARNet::PRNG.new(42)
    v2 = Array.new(10000) { d.rand(2) }
    _log("rand(2) in range: #{v2.uniq.sort == [0, 1]}  balance: #{(v2.sum.to_f / v2.length).round(3)}")
    seed = ARNet.derive_seed(ARNet.new_nonce, ARNet.new_nonce)
    _log("sample derived seed -> first draws: #{Array.new(3) { ARNet::PRNG.new(seed).rand(100) }.inspect}")
  end

  def self._log(msg)
    line = "[ARNet] #{msg}"
    if defined?(Console) && Console.respond_to?(:echo_li)
      Console.echo_li(line)
    elsif defined?(pbMessage)
      p line
    else
      puts line
    end
  end

  def self._sleep_frame
    if defined?(Graphics) && Graphics.respond_to?(:update)
      Graphics.update
      Input.update if defined?(Input)
    else
      sleep(1.0 / 60.0)
    end
  end
end
