#===============================================================================
# Another Red Online — Battle Recording Scene  [025]  (Phase 1/2)
#
# Wraps the real Battle::Scene. Every @scene.pbXXX call is intercepted,
# encoded into a replayable event entry, and either forwarded or suppressed:
#
#   headless=false (Phase 1 / command phase): captures AND forwards → passthrough.
#   headless=true  (Phase 2 attack/EOR sim):  captures but does NOT forward,
#                  so the canonical sim runs silently; EventPlayer ([026]) renders.
#
# ALWAYS_FORWARD: control-flow methods that need real return values from the UI
#   (party selection, etc.). These are forwarded even in headless mode, but are
#   NOT replayed by EventPlayer — the scene received them during the sim pass.
# NOISE: pbUpdate / pbForceEndSpeech — skipped entirely (never recorded; 100+
#   calls per turn that carry no rendering information).
#
# Event encoding for EventPlayer:
#   Battle::Battler → ARNet::BRef(logical_index)   (rebuilt by EventPlayer)
#   Battle::Move    → ARNet::MRef(move_object)     (short-lived, by-ref OK)
#   Everything else → stored as-is
#
# Log file: "ARNet_Logs/arnet_battle_events_{side}.log" (side 0=host, 1=guest;
# ARNet.log_path from [000]). Compare host and guest logs to verify symmetry.
#===============================================================================
module ARNet
  BRef = Struct.new(:idx)   # logical battler index reference
  MRef = Struct.new(:obj)   # move object reference (valid within the same turn)

  class RecordingScene
    attr_reader   :events
    attr_accessor :headless

    # Dropped entirely — never recorded, never forwarded.
    NOISE = %i[pbUpdate pbForceEndSpeech].freeze

    # Forwarded to the real scene even in headless mode (input methods that need
    # a real return value). EventPlayer skips replaying these — the real scene
    # already received them during the headless sim pass.
    ALWAYS_FORWARD = %i[pbPartyScreen pbChooseEnemyCommand].freeze

    def initialize(real_scene, side)
      @real     = real_scene
      @side     = side
      @events   = []
      @headless = false
      @buf      = []
      @seq      = 0
      @log_path = ARNet.log_path("arnet_battle_events_#{side}.log")
      begin
        File.open(@log_path, "w") { |f| f.puts("[ARNet:RecordingScene side=#{side}] #{Time.now}") }
      rescue
      end
    end

    # Drain all captured events and reset the list.
    def drain
      evts = @events.dup
      @events.clear
      evts
    end

    # Reference to the underlying real scene (used by EventPlayer to replay).
    def real_scene; @real; end

    # --- Delegation -----------------------------------------------------------

    # Battler display ivars snapshotted per event so EventPlayer can rewind them
    # to the exact moment each scene call was made (see DISP_SNAP note below).
    DISP_IVARS = { hp: :@hp, thp: :@totalhp, pk: :@pokemon,
                   nm: :@name, lv: :@level, st: :@status, sc: :@statusCount }.freeze

    def method_missing(name, *args, &block)
      return if NOISE.include?(name)
      always = ALWAYS_FORWARD.include?(name)
      @seq  += 1
      entry  = { seq: @seq, call: name, enc: _encode(args),
                 log: _summarize(args), disp: _display_snapshot }
      @events << entry
      _enqueue(entry, name == :pbEndBattle)
      # Always forward control-flow methods; otherwise only forward when not headless.
      return @real.send(name, *args, &block) if always || !@headless
      nil
    end

    def respond_to_missing?(name, include_private = false)
      @real.respond_to?(name, include_private) || super
    end

    # Let class/type checks see through to the real scene so any is_a? guards
    # in the engine pass after we replace @scene.
    def is_a?(klass);        @real.is_a?(klass)        || super; end
    def kind_of?(klass);     @real.kind_of?(klass)     || super; end
    def instance_of?(klass); @real.instance_of?(klass) || super; end

    private

    # --- Display-state snapshot -----------------------------------------------
    # A scene call captured now is REPLAYED later ([026]), after the headless sim
    # has already advanced every battler to its final post-turn state. The data
    # box / recall / send-out animations read the LIVE battler, so without this
    # they'd show the FINAL Pokémon (HP already drained, or the just-switched-in
    # mon during the recall of the outgoing one). We snapshot the small set of
    # display ivars the boxes read (hp/totalhp/pokemon/name/level/status) at the
    # moment of the call; EventPlayer restores them before each replayed call and
    # restores the true final state afterward, so the sim is never mutated.
    def _display_snapshot
      btl = @real.instance_variable_get(:@battle)
      return {} unless btl
      btl.battlers.each_with_object({}) do |bt, h|
        next unless bt
        h[bt.index] = DISP_IVARS.each_with_object({}) do |(k, iv), s|
          s[k] = bt.instance_variable_get(iv)
        end
      end
    rescue
      {}
    end

    # --- Event encoding -------------------------------------------------------

    def _encode(args); args.map { |a| _enc(a) }; end

    def _enc(a)
      case a
      when Integer, Float, Symbol, String, NilClass, TrueClass, FalseClass
        a
      when Array
        a.map { |x| _enc(x) }
      else
        if a.respond_to?(:index) && a.respond_to?(:species)
          ARNet::BRef.new(a.index)
        elsif a.respond_to?(:id) && a.respond_to?(:name) && !a.respond_to?(:index)
          ARNet::MRef.new(a)
        else
          a
        end
      end
    end

    # --- Log summary (human-readable) -----------------------------------------

    def _summarize(args); args.map { |a| _val(a) }; end

    def _val(a)
      case a
      when Integer, Float, Symbol, String, NilClass, TrueClass, FalseClass
        a
      when Array
        a.map { |x| _val(x) }
      else
        if a.respond_to?(:index) && a.respond_to?(:species)
          h = { b: a.index, sp: a.species.to_s }
          h[:hp]  = "#{a.hp}/#{a.totalhp}" if a.respond_to?(:hp) && a.respond_to?(:totalhp)
          h[:fnt] = true                    if a.respond_to?(:fainted?) && a.fainted?
          h
        elsif a.respond_to?(:id) && a.respond_to?(:name) && !a.respond_to?(:index)
          { move: a.id.to_s }
        elsif a.respond_to?(:name)
          { name: a.name.to_s, cls: a.class.to_s }
        else
          a.class.to_s
        end
      end
    end

    def _enqueue(entry, force = false)
      @buf << ("[%04d] %-34s %s" % [entry[:seq], entry[:call], entry[:log].inspect])
      return unless force || @buf.size >= 20
      begin
        File.open(@log_path, "a") { |f| f.puts(@buf) }
      rescue
      end
      @buf = []
    end
  end
end

#===============================================================================
# Hook: inject RecordingScene after arnet_attach sets side + seeds PRNG.
#===============================================================================
class Battle
  alias_method :arnet_orig_attach_rec, :arnet_attach
  def arnet_attach(link)
    arnet_orig_attach_rec(link)
    @arnet_recording = ARNet::RecordingScene.new(@scene, link.side)
    @scene           = @arnet_recording
  end

  def arnet_events;     @arnet_recording&.events     || []; end
  def arnet_real_scene; @arnet_recording&.real_scene;      end
end
