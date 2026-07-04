#===============================================================================
# Another Red Online — session state machine
#
# Wraps NetClient: hello -> code-room matchmaking -> peer handshake (bhello nonce
# exchange -> side/seed) -> battle setup (team preview + selection) -> battle_ready.
# Drive with #update each frame; read #phase / callbacks.
#
# Phase flow:
#   :connecting -> :idle -> :searching -> :handshake -> :ready
#                 -> :team_exchange -> :battle_ready
#   (any -> :error / :closed)
#===============================================================================
module ARNet
  class Session
    attr_reader :phase, :side, :seed, :match_id, :opponent_name, :error, :error_code
    attr_reader :format, :ruleset, :peer_party, :opponent_gender, :opponent_trainer_type

    def initialize(host, port = ARNet::DEFAULT_PORT, name: "Trainer", gender: 0, trainer_type: nil)
      @client = NetClient.new(host, port)
      @name = name
      @gender = gender            # 0=male / 1=female — sent in bhello (legacy/aux)
      @trainer_type = trainer_type # our player trainer type symbol — drives the intro sprite
      @opponent_gender = nil      # peer's gender (arrives with their bhello)
      @opponent_trainer_type = nil # peer's trainer type (String, from their bhello)
      @phase = :connecting
      @nonce = ARNet.new_nonce
      @peer_nonce = nil
      @ruleset = ARNet.default_ruleset
      @format = nil
      @hello_sent = false
      # battle-setup state
      @local_team = nil       # Array<Hash> (serialized, sent to peer)
      @peer_team_data = nil   # Array<Hash> (received from peer, validated)
      @peer_party = nil       # Array<Pokemon> (rebuilt from peer team)
      @peer_team_ok = false   # peer accepted our team
      @local_picks = nil      # Array<Integer> party indices we selected
      @peer_picks = nil       # Array<Integer> party indices peer selected
    end

    def update
      @client.update
      if @client.closed?
        @phase = (@client.state == :error ? :error : :closed)
        @error = @client.last_error
        return
      end
      if @client.connected? && !@hello_sent
        @client.send_msg({ "t" => "hello", "proto" => ARNet::PROTO, "name" => @name })
        @hello_sent = true
      end
      @client.poll.each { |m| _on_message(m) }
    end

    # --- matchmaking API (code-share only) ---
    def create_room(format, ruleset = nil)
      @format = format; @ruleset = ruleset || ARNet.default_ruleset
      @client.send_msg({ "t" => "create_room", "format" => format, "ruleset" => @ruleset })
      @phase = :searching
    end

    def join_room(code)
      @client.send_msg({ "t" => "join_room", "code" => code })
      @phase = :searching
    end

    # Random matchmaking: join the shared quick-match queue for `format`. The server
    # pairs us with the next waiting player on the SAME format + mod_version, then
    # drives the identical `matched` flow as a code room (nonce side decision, seed,
    # team exchange, lockstep). We send our default (ranked) ruleset; the server
    # relays the waiting player's copy to both peers so ruleset_hash always agrees.
    # on_queued(format) fires while we wait for an opponent.
    def start_quick_match(format)
      @format = format
      @ruleset = ARNet.default_ruleset
      @client.send_msg({ "t" => "quick_match", "format" => format,
                         "mod_version" => ARNet::MOD_VERSION, "ruleset" => @ruleset })
      @phase = :searching
    end

    # --- battle-setup API (call after on_ready fires) ---
    # Send our full 6-mon team (serialized Hashes from ARNet::Team.party_to_data).
    def submit_team(team_data)
      @local_team = team_data
      send_battle({ "t" => "team", "mons" => team_data })
      @phase = :team_exchange if @phase == :ready
      _maybe_battle_ready
    end

    # For selection formats (single3/double4): send our chosen party indices.
    def submit_selection(picks)
      @local_picks = picks
      send_battle({ "t" => "selection", "picks" => picks })
      _maybe_battle_ready
    end

    # Un-confirm a selection that hasn't started a battle yet (the peer hasn't
    # also confirmed, so we're not :battle_ready). Clears both sides' pick state
    # so _maybe_battle_ready can't fire on the stale picks while we re-select.
    def retract_selection
      return if @phase == :battle_ready
      @local_picks = nil
      send_battle({ "t" => "unselect" })
    end

    # relay + FLUSH: push the frame to the socket immediately. Callers in the
    # lockstep often send and then run local animations before their next await,
    # so a buffered-only send would strand the message until much later (see
    # NetClient#flush). Flushing here keeps the peer's screen in step.
    def send_battle(data); @client.relay(data); @client.flush; end
    def close; @client.close; @phase = :closed; end

    # Override / set these procs to receive events.
    #   on_room_created(code) / on_queued(format) / on_ready(side, seed)
    #   on_peer_team(team_data) / on_battle_ready(info hash) / on_peer_msg(data)
    #   on_peer_left(reason)
    attr_accessor :on_room_created, :on_queued, :on_ready, :on_peer_team,
                  :on_battle_ready, :on_peer_msg, :on_peer_left

    private

    def _on_message(m)
      case m["t"]
      when "hello_ok"
        @phase = :idle
      when "room_created"
        @room_code = m["code"]
        on_room_created&.call(m["code"])
      when "queued"
        # Quick-match: waiting in the queue for an opponent (no room code).
        on_queued&.call(m["format"])
      when "matched"
        @match_id = m["match_id"]
        @opponent_name = m.dig("opponent", "name")
        @format ||= m["format"]
        @ruleset = m["ruleset"] || @ruleset
        @phase = :handshake
        # begin peer handshake: send our bhello nonce
        send_battle({ "t" => "bhello", "proto" => ARNet::PROTO,
                      "nonce" => @nonce, "gender" => @gender,
                      "ttype" => (@trainer_type ? @trainer_type.to_s : nil),
                      "mver" => ARNet::MOD_VERSION,
                      "ruleset_hash" => ARNet.ruleset_hash(@ruleset) })
      when "peer_msg"
        _on_peer(m["data"])
      when "peer_left"
        @phase = :closed
        on_peer_left&.call(m["reason"])
      when "error"
        @error = m["msg"]; @error_code = m["code"]; @phase = :error
      end
    end

    def _on_peer(data)
      case data["t"]
      when "bhello"
        @peer_nonce = data["nonce"]
        @opponent_gender = data["gender"]           # legacy/aux
        @opponent_trainer_type = data["ttype"]      # drives the opponent intro sprite ([012])
        # Refuse cross-version matches — differing battle logic would desync.
        if data["mver"] != ARNet::MOD_VERSION
          @error = "mod version mismatch (me #{ARNet::MOD_VERSION}, peer #{data["mver"]})"
          @error_code = "version"; @phase = :error
          send_battle({ "t" => "abort", "reason" => "version" })
          return
        end
        if data["ruleset_hash"] != ARNet.ruleset_hash(@ruleset)
          @error = "ruleset mismatch"; @phase = :error
          send_battle({ "t" => "abort", "reason" => "ruleset" })
          return
        end
        @side = ARNet.my_side(@nonce, @peer_nonce)
        @seed = ARNet.derive_seed(@nonce, @peer_nonce)
        @phase = :ready
        on_ready&.call(@side, @seed)
      when "team"
        ok, res = ARNet::Team.data_to_party(data["mons"], @ruleset)
        if ok
          @peer_team_data = data["mons"]
          @peer_party = res
          send_battle({ "t" => "team_ok" })
          on_peer_team&.call(data["mons"])
          _maybe_battle_ready
        else
          @error = "peer team invalid: #{res}"; @phase = :error
          send_battle({ "t" => "abort", "reason" => "bad_team" })
        end
      when "team_ok"
        @peer_team_ok = true
        _maybe_battle_ready
      when "selection"
        @peer_picks = data["picks"]
        _maybe_battle_ready
      when "unselect"
        # Peer un-confirmed before the battle started — drop their picks so we
        # don't advance to :battle_ready until they re-select.
        @peer_picks = nil
      when "abort"
        @error = "peer aborted: #{data["reason"]}"
        @error_code = data["reason"]   # e.g. "version" → friendly message in [011]
        @phase = :error
      else
        on_peer_msg&.call(data)   # battle-layer messages (choices/checksum...)
      end
    end

    # Advance to :battle_ready once both teams are exchanged+accepted and (for
    # selection formats) both pick lists are in with the right count.
    def _maybe_battle_ready
      return if @phase == :battle_ready || @phase == :error
      return unless @local_team && @peer_party && @peer_team_ok
      if ARNet.needs_selection?(@format)
        n = ARNet.picks_for(@format)
        return unless @local_picks && @peer_picks
        return unless @local_picks.length == n && @peer_picks.length == n
      end
      @phase = :battle_ready
      on_battle_ready&.call(_battle_info)
    end

    def _battle_info
      {
        "side"       => @side,
        "seed"       => @seed,
        "format"     => @format,
        "ruleset"    => @ruleset,
        "my_team"    => @local_team,      # Array<Hash>
        "peer_team"  => @peer_team_data,  # Array<Hash>
        "peer_party" => @peer_party,      # Array<Pokemon> (prebuilt)
        "my_picks"   => @local_picks,
        "peer_picks" => @peer_picks
      }
    end
  end
end
