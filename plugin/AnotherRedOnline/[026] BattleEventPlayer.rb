#===============================================================================
# Another Red Online — Battle Event Player  [026]  (Phase 2)
#
# ARNet::EventPlayer replays the event list captured by RecordingScene on the
# real Battle::Scene. BRef/MRef encoded args are resolved back to canonical
# battler/move objects from the live battle state.
#
# [012]'s presentation overrides (pbBattlerPosition, sprite flip, message
# perspective, pbFindMoveAnimation, etc.) remain active throughout — canonical
# battler objects are passed unchanged, so all positioning and direction logic
# already in [012] applies correctly without any additional index mapping here.
#
# Turn-loop hooks (Phase 2):
#   pbAttackPhase       — headless sim → EventPlayer replay
#   pbEndOfRoundPhase   — headless sim (includes [009] checksum exchange) → replay
#
# Both phases use RecordingScene.headless=true during the sim pass: all @scene
# calls are captured but NOT forwarded to the real scene. ALWAYS_FORWARD methods
# (party screen, enemy command) are exempt: the real scene receives them during
# the sim pass so input works correctly; EventPlayer skips replaying them.
#
# Each event entry carries a :disp snapshot ({idx => {hp,totalhp,pokemon,name,
# level,status,statusCount}}) captured at the moment the scene call was made
# during the headless sim. _dispatch restores those ivars before calling the
# scene method, so the boxes render the state AS OF that call instead of the
# final post-turn state. This fixes both:
#   - HP bars draining before the move animation (partial-step HP), and
#   - a switch showing the incoming Pokémon on the data box during the RECALL of
#     the outgoing one (pbRefreshOne/refresh read the live battler, which the sim
#     had already advanced to the switched-in mon).
# play() snapshots the true post-sim state first and restores it in an ensure, so
# this display rewind never mutates the canonical (deterministic) battler state.
#===============================================================================
module ARNet
  class EventPlayer
    # Never replay: NOISE was never captured; ALWAYS_FORWARD was already executed
    # by the real scene during the headless sim pass.
    SKIP_REPLAY = (ARNet::RecordingScene::NOISE +
                   ARNet::RecordingScene::ALWAYS_FORWARD).freeze

    # Wire key -> battler ivar, mirroring [025]'s DISP_IVARS. Used to rewind each
    # battler's display state to the recorded moment before a call is replayed.
    DISP_IVARS = { hp: :@hp, thp: :@totalhp, pk: :@pokemon,
                   nm: :@name, lv: :@level, st: :@status, sc: :@statusCount }.freeze

    def initialize(battle, real_scene)
      @battle = battle
      @scene  = real_scene
    end

    def play(events)
      # The battlers currently hold the TRUE post-sim (canonical) state. Replay
      # rewinds their display ivars per event; capture the truth now and restore
      # it afterward so the rendering pass never mutates the deterministic sim.
      final = _capture_display
      events.each { |e| _dispatch(e) }
    ensure
      _apply_display(final) if final
    end

    private

    def _dispatch(e)
      return if SKIP_REPLAY.include?(e[:call])
      _apply_display(e[:disp]) if e[:disp] && !e[:disp].empty?
      args = _rebuild(e[:enc])
      @scene.send(e[:call], *args)
    end

    # Snapshot every battler's display ivars (returns nil on any failure so the
    # ensure-restore is skipped rather than corrupting state with a partial map).
    def _capture_display
      @battle.battlers.each_with_object({}) do |b, h|
        next unless b
        h[b.index] = DISP_IVARS.each_with_object({}) do |(k, iv), s|
          s[k] = b.instance_variable_get(iv)
        end
      end
    rescue
      nil
    end

    # Restore a snapshot (from [025] or _capture_display) onto the live battlers.
    def _apply_display(snap)
      snap.each do |idx, fields|
        b = @battle.battlers[idx]
        next unless b
        fields.each { |k, v| iv = DISP_IVARS[k]; b.instance_variable_set(iv, v) if iv }
      end
    rescue
      nil
    end

    # Rebuild encoded args: BRef → battler object, MRef → move object, else as-is.
    def _rebuild(encoded)
      return [] if encoded.nil?
      encoded.map { |a| _map(a) }
    end

    def _map(a)
      case a
      when ARNet::BRef then @battle.battlers[a.idx]
      when ARNet::MRef then a.obj
      when Array       then a.map { |x| _map(x) }
      else                  a
      end
    end
  end
end

#===============================================================================
# Phase 2 turn-loop hooks: headless sim → EventPlayer replay.
#
# Both methods clear any previously accumulated events, flip headless on,
# run the canonical phase (scene calls captured but suppressed), flip headless
# off, then replay the captured events on the real scene via EventPlayer.
#
# [009]'s pbEndOfRoundPhase alias is already in place when [026] loads
# (026 > 009), so aliasing pbEndOfRoundPhase here captures [009]'s version,
# which includes both the canonical phase and the desync checksum exchange.
# The checksum exchange makes no @scene calls (pure network I/O), so it runs
# safely inside the headless window; the player sees animations AFTER the
# checksum confirms state consistency.
#===============================================================================
class Battle
  alias_method :arnet_orig_pbAttackPhase_ep,      :pbAttackPhase
  alias_method :arnet_orig_pbEndOfRoundPhase_ep,  :pbEndOfRoundPhase

  def pbAttackPhase
    return arnet_orig_pbAttackPhase_ep unless arnet_online?
    @arnet_recording.events.clear
    @arnet_recording.headless = true
    begin
      arnet_orig_pbAttackPhase_ep
    ensure
      @arnet_recording.headless = false
    end
    ARNet::EventPlayer.new(self, @arnet_recording.real_scene).play(@arnet_recording.drain)
  end

  def pbEndOfRoundPhase
    return arnet_orig_pbEndOfRoundPhase_ep unless arnet_online?
    @arnet_recording.events.clear
    @arnet_recording.headless = true
    begin
      arnet_orig_pbEndOfRoundPhase_ep   # canonical sim + [009] checksum exchange
    ensure
      @arnet_recording.headless = false
    end
    ARNet::EventPlayer.new(self, @arnet_recording.real_scene).play(@arnet_recording.drain)
  end
end
