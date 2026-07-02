#===============================================================================
# Another Red Online — in-battle link controller (Phase 4)
#
# Bridges a live Battle to the NetSession during the lockstep loop. Owns the
# per-turn exchange of `choices` and `checksum` messages and the frame-pumped
# wait (never a blocking socket read — we keep Graphics/Input updating so the app
# stays responsive while waiting on the peer).
#
# Messages (peer<->peer, via Session#send_battle / on_peer_msg):
#   { "t":"choices",  "turn":N, "acts":[<choice h>...] }
#   { "t":"checksum", "turn":N, "hash":"<hex>" }
#   { "t":"switch",   "seq":N, "idx":<battler>, "pt":<partyIdx> }  # faint/mid-battle replacement
#   { "t":"forfeit" }
#===============================================================================
module ARNet
  # Raised out of a blocking selection menu when the peer forfeits/disconnects
  # mid-menu, so we can react immediately instead of only after the local player
  # commits an action. Caught in Battle#arnet_run_choice_menu.
  class PeerGone < StandardError; end

  class BattleLink
    # Frame budgets (60 fps). Turn input is human-paced; checksum is near-instant.
    CHOICES_TIMEOUT  = 60 * 120   # 2 min to receive peer's turn choices
    CHECKSUM_TIMEOUT = 60 * 30    # 30 s to receive peer's end-of-turn checksum
    SWITCH_TIMEOUT   = 60 * 120   # 2 min to receive peer's forced replacement (human-paced)

    attr_reader   :session, :side, :seed, :peer_left, :forfeited
    # Peer's chess-clock state (Hash {"bank"=>secs,"out"=>bool}) piggybacked on
    # their latest choices message; nil until the first turn is exchanged.
    attr_reader   :peer_clock
    # The live Battle::Scene, set by the launcher once the battle exists. When
    # present, the frame-pumped wait ticks the scene (idle Pokémon animations,
    # lineup anims) instead of a bare Graphics.update, so the screen keeps
    # breathing while we wait on the peer instead of hard-freezing.
    attr_accessor :scene

    def initialize(session)
      @session = session
      @side    = session.side
      @seed    = session.seed
      @scene   = nil
      @choices_inbox  = {}   # turn -> acts array
      @checksum_inbox = {}   # turn -> hash string
      @switch_inbox   = {}   # seq  -> party index of peer's replacement
      @peer_left  = false
      @forfeited  = false    # peer forfeited
      @peer_clock = nil      # peer's latest {bank,out} (chess clock)
      # route battle-layer peer messages here
      @session.on_peer_msg = method(:_on_msg)
      @session.on_peer_left = proc { |_r| @peer_left = true }
    end

    def _on_msg(data)
      case data["t"]
      when "choices"
        @choices_inbox[data["turn"]] = data["acts"]
        @peer_clock = data["clk"] if data["clk"]
      when "checksum" then @checksum_inbox[data["turn"]] = data["hash"]
      when "switch"   then @switch_inbox[data["seq"]]    = data["pt"]
      when "forfeit"  then @forfeited = true
      end
    end

    #--- send -----------------------------------------------------------------
    def send_choices(turn, acts, clk = nil)
      msg = { "t" => "choices", "turn" => turn, "acts" => acts }
      msg["clk"] = clk if clk
      @session.send_battle(msg)
    end

    def send_checksum(turn, hash)
      @session.send_battle({ "t" => "checksum", "turn" => turn, "hash" => hash })
    end

    def send_switch(seq, idx, idxParty)
      @session.send_battle({ "t" => "switch", "seq" => seq, "idx" => idx, "pt" => idxParty })
    end

    def send_forfeit
      @session.send_battle({ "t" => "forfeit" })
    end

    #--- await (frame-pumped, non-blocking on the socket) ---------------------
    # Returns the opponent's acts array for `turn`, or nil on timeout/disconnect.
    def await_choices(turn)
      _pump_until(CHOICES_TIMEOUT) { @choices_inbox.delete(turn) }
    end

    # Returns the opponent's checksum hash for `turn`, or nil on timeout/disconnect.
    def await_checksum(turn)
      _pump_until(CHECKSUM_TIMEOUT) { @checksum_inbox.delete(turn) }
    end

    # Returns the opponent's replacement party index for `seq`, or nil on
    # timeout/disconnect. (party index 0 is truthy in Ruby, so 0 returns fine.)
    def await_switch(seq)
      _pump_until(SWITCH_TIMEOUT) { @switch_inbox.delete(seq) }
    end

    private

    def _pump_until(timeout_frames)
      frames = 0
      loop do
        @session.update
        return nil if @session.phase == :error || @session.phase == :closed || @peer_left || @forfeited
        got = yield
        return got if got
        if @scene && @scene.respond_to?(:pbGraphicsUpdate)
          # Scene tick WITHOUT pbInputUpdate: pbGraphicsUpdate advances lineup
          # animations + backdrop + Graphics.update; pbFrameUpdate advances the
          # idle Pokémon / shadow / data-box sprites. We deliberately skip
          # pbInputUpdate (which maps BACK -> pbAbort) so waiting can't abort the
          # online battle; we still pump raw Input.update to keep key state fresh.
          @scene.pbGraphicsUpdate
          @scene.pbFrameUpdate
          Input.update if defined?(Input) && Input.respond_to?(:update)
        elsif defined?(Graphics) && Graphics.respond_to?(:update)
          Graphics.update
          Input.update if defined?(Input) && Input.respond_to?(:update)
        end
        frames += 1
        return nil if frames > timeout_frames
      end
    end
  end
end
