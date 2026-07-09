#===============================================================================
# Another Red Online — team serialization, normalization & validation
#
# Phase 3: turns Essentials `Pokemon` objects into plain-data Hashes (JSON-safe)
# and back. The wire format is pure fields only — NEVER Marshal (adversarial
# bytes = RCE). Reconstruction goes through the normal `Pokemon` constructor and
# setters, which doubles as validation.
#
# Battle-only normalization (PROTOCOL.md §3.1 / §7.2):
#   - level is forced to ruleset["level_cap"] (50), transmitted level ignored.
#   - every IV is forced to ruleset["iv_flat"] (31 / 6V), transmitted IVs ignored.
# These apply to the reconstructed *battle copy* only; the sender's real save
# data is untouched (we read from a copy and the receiver builds a fresh mon).
#===============================================================================
module ARNet
  module Team
    module_function

    # Strict move-legality: reject any move outside the species' legal pool
    # (level-up ∪ tutor ∪ egg ∪ prevolution chain — see legal_move_pool).
    #
    # This is a SUPERSET of the engine's own learn predicate: in this build TM/HM
    # teaching is gated by Pokemon#compatible_with_move? (= tutor ∪ level-up ∪ egg,
    # 263_Item_Utilities.rb:719 / 273_Pokemon.rb:708), i.e. there is NO separate TM
    # pool. So there is no "TM gap": anything a Pokémon can legitimately know in
    # this game is in the pool → zero false positives. The opponent re-runs this on
    # the received team, so an edited/impossible mon is rejected regardless of how
    # it was built (data tampering included).
    STRICT_MOVES = true

    # Ordered main-stat ids (:HP, :ATTACK, ...). Built once from GameData.
    def stat_ids
      @stat_ids ||= begin
        ids = []
        GameData::Stat.each_main { |s| ids << s.id }
        ids
      end
    end

    #--- serialize ------------------------------------------------------------
    # Pokemon -> plain Hash (JSON-safe). Reads fields only; does not mutate pkmn.
    def pokemon_to_h(pkmn)
      iv = {}; ev = {}
      stat_ids.each do |sid|
        iv[sid.to_s] = pkmn.iv[sid]
        ev[sid.to_s] = pkmn.ev[sid]
      end
      h = {
        "species"   => pkmn.species.to_s,
        "form"      => pkmn.form_simple,
        "gender"    => pkmn.gender,
        "shiny"     => pkmn.shiny?,
        "nature"    => pkmn.nature&.id&.to_s,   # .nature (not nature_id) forces resolution
                                                # so a personalID-derived nature is made concrete
        "ability"   => pkmn.ability_id&.to_s,
        "item"      => pkmn.item_id&.to_s,
        "moves"     => pkmn.moves.map { |m| { "id" => m.id.to_s, "ppup" => m.ppup } },
        "iv"        => iv,
        "ev"        => ev,
        "happiness" => pkmn.happiness,
        "ball"      => pkmn.poke_ball.to_s
      }
      # DBK extras — present only if those plugins are installed.
      if pkmn.respond_to?(:tera_type) && (tt = pkmn.tera_type)
        h["tera_type"] = tt.is_a?(Symbol) ? tt.to_s : (tt.respond_to?(:id) ? tt.id.to_s : tt.to_s)
      end
      h["gmax"]        = pkmn.gmax_factor   if pkmn.respond_to?(:gmax_factor)
      h["dynamax_lvl"] = pkmn.dynamax_lvl   if pkmn.respond_to?(:dynamax_lvl)
      h
    end

    # Array<Pokemon> -> Array<Hash>
    def party_to_data(party)
      party.compact.map { |pkmn| pokemon_to_h(pkmn) }
    end

    # Pre-flight self-check. Returns [pkmn, reason] for the first party member
    # whose serialized form fails validation, or nil if the whole party is legal.
    # Lets us warn the LOCAL player (naming the mon/move) before entering the
    # matchmaking queue. This is UX only — the opponent re-validates on receive
    # ([003]), which is the actual anti-cheat guard (no trust in self-report).
    def first_illegal(party, ruleset = ARNet.default_ruleset)
      mons = party.compact
      mons.each do |pkmn|
        ok, reason = validate_h(pokemon_to_h(pkmn), ruleset)
        return [pkmn, reason] unless ok
      end
      # Team-wide clauses: return the offending (second-occurrence) mon so the
      # local pre-check UI can name it. Mirrors team_clause_violation exactly.
      if ruleset["species_clause"]
        seen = {}
        mons.each do |pkmn|
          key = pkmn.species.to_s
          return [pkmn, "duplicate species"] if seen[key]
          seen[key] = true
        end
      end
      if ruleset["item_clause"]
        seen = {}
        mons.each do |pkmn|
          it = pkmn.item_id
          next if it.nil?
          key = it.to_s
          return [pkmn, "duplicate item"] if seen[key]
          seen[key] = true
        end
      end
      nil
    end

    #--- team-wide clauses ----------------------------------------------------
    # Species/item clauses checked on the SERIALIZED hashes, so host and guest
    # evaluate an identical team representation. Returns a reason String or nil.
    # This is the authoritative guard: the receiver re-runs it on the peer's
    # team, so it needs no trust in the sender.
    def team_clause_violation(arr, ruleset = ARNet.default_ruleset)
      if ruleset["species_clause"]
        seen = {}
        arr.each do |h|
          key = h["species"].to_s
          return "duplicate species #{key}" if seen[key]
          seen[key] = true
        end
      end
      if ruleset["item_clause"]
        seen = {}
        arr.each do |h|
          it = h["item"]
          next if it.nil? || it.to_s.empty?
          key = it.to_s
          return "duplicate item #{key}" if seen[key]
          seen[key] = true
        end
      end
      nil
    end

    #--- validate -------------------------------------------------------------
    # Returns [ok(bool), reason(String|nil)]. Existence/counts/EV/ability are hard
    # rejects; move legality is soft unless STRICT_MOVES (see note above).
    # Champions-style stat budget (66 SP × 8 EV each) raises the online EV ceilings
    # so teams built with the in-game EV trainer ([022] EVTraining) validate:
    #   32 SP/stat = 256 EV  (engine cap 252),  66 SP total = 528 EV (engine cap 510).
    # Both peers use these identical constants (baked shared build) → deterministic.
    ONLINE_EV_STAT_LIMIT = 256
    ONLINE_EV_LIMIT      = 528

    def validate_h(h, ruleset = ARNet.default_ruleset)
      return [false, "not a hash"] unless h.is_a?(Hash)
      sp = h["species"]
      return [false, "bad species"] unless sp && GameData::Species.exists?(sp.to_sym)
      species = sp.to_sym
      form    = h["form"].is_a?(Integer) ? h["form"] : 0
      sp_data = GameData::Species.get_species_form(species, form) ||
                GameData::Species.get(species)

      if h["ability"] && !h["ability"].to_s.empty?
        ab = h["ability"].to_sym
        return [false, "unknown ability"] unless GameData::Ability.exists?(ab)
        legal = (sp_data.abilities + sp_data.hidden_abilities).compact
        return [false, "illegal ability for species"] unless legal.include?(ab)
      end
      if h["nature"] && !h["nature"].to_s.empty?
        return [false, "unknown nature"] unless GameData::Nature.exists?(h["nature"].to_sym)
      end
      if h["item"] && !h["item"].to_s.empty?
        return [false, "unknown item"] unless GameData::Item.exists?(h["item"].to_sym)
      end

      moves = h["moves"] || []
      return [false, "no moves"]        if moves.empty?
      return [false, "too many moves"]  if moves.length > Pokemon::MAX_MOVES
      moves.each do |m|
        return [false, "bad move entry"] unless m.is_a?(Hash) && m["id"]
        return [false, "unknown move #{m["id"]}"] unless GameData::Move.exists?(m["id"].to_sym)
      end
      if STRICT_MOVES
        pool = legal_move_pool(species, form)
        moves.each do |m|
          mid = m["id"].to_sym
          return [false, "illegal move #{mid}"] unless pool.include?(mid)
        end
      end

      ev_total = 0
      stat_ids.each do |sid|
        e = h.dig("ev", sid.to_s) || 0
        return [false, "ev out of range"] unless e.is_a?(Integer) && e >= 0 && e <= ONLINE_EV_STAT_LIMIT
        ev_total += e
      end
      return [false, "ev total > #{ONLINE_EV_LIMIT}"] if ev_total > ONLINE_EV_LIMIT

      [true, nil]
    end

    # Union of level-up (all levels) + tutor + egg moves, including the prevolution
    # chain. This equals-or-exceeds the engine's own compatible_with_move? predicate
    # (which also gates TM/HM teaching in this build), so it needs no separate TM
    # pool and produces no false positives — see the STRICT_MOVES note above.
    # Moves a form change GRANTS that live in NO form's learnset, so the per-form
    # lookup below can't see them. Mirror of the base game's MultipleForms handlers
    # (280_FormHandlers.rb). Keyed species => { form => [moves] }.
    #
    # Only Rotom and Necrozma need this: their signature moves are in no learnset.
    # Calyrex/Kyurem keep theirs IN each form's learnset (per-form lookup covers
    # them), and Zacian/Meloetta/Aegislash/etc. only gain their signature move
    # DURING battle and revert on leaving, so a serialized (out-of-battle) team
    # never holds them. A mon in form F may legally hold ONLY form F's granted
    # move(s): base form 0 forgets them on reverting (verified: Rotom/Necrozma/
    # Calyrex onSetForm forget on form 0), so a form-0 mon holding a signature
    # move stays illegal — this is what catches edit-mons (e.g. a plain Rotom
    # carrying Overheat + Hydro Pump).
    FORM_GRANTED_MOVES = {
      :ROTOM    => { 1 => [:OVERHEAT], 2 => [:HYDROPUMP], 3 => [:BLIZZARD],
                     4 => [:AIRSLASH], 5 => [:LEAFSTORM] },
      :NECROZMA => { 1 => [:SUNSTEELSTRIKE], 2 => [:MOONGEISTBEAM] }
    }

    def legal_move_pool(species, form = 0)
      pool = []
      seen = {}
      stack = [species]
      until stack.empty?
        sp = stack.pop
        next if seen[sp]
        seen[sp] = true
        # Per-form learnset: a mon may only hold moves its OWN form can learn.
        data = GameData::Species.get_species_form(sp, form) || GameData::Species.get(sp)
        next unless data
        data.moves.each { |lvl, mid| pool << mid }     # [level, move_id]
        pool.concat(data.tutor_moves) if data.respond_to?(:tutor_moves)
        pool.concat(data.egg_moves)   if data.respond_to?(:egg_moves)
        # Walk the prevolution chain so evolved mons inherit egg/prevo-only moves
        # (e.g. Grimmsnarl legally holding Impidimp's egg move Parting Shot).
        # NOTE: get_evolutions(true) does NOT yield prevolutions — the engine always
        # skips evo[3] entries and returns only [species, method, param] (no is_prevo
        # flag), so the old `evo[3]` walk was a no-op. get_previous_species is the
        # engine's canonical prevolution accessor; walk it one step per species.
        if data.respond_to?(:get_previous_species)
          prevo = data.get_previous_species
          stack << prevo if prevo && prevo != sp
        elsif data.respond_to?(:evolutions)
          data.evolutions.each { |evo| stack << evo[0] if evo[3] }
        end
      end
      # Add the move(s) the CURRENT form gains via form change (absent from every
      # learnset). Only this form's — so a wrong-form or multi-signature mon fails.
      granted = FORM_GRANTED_MOVES[species]
      pool.concat(granted[form]) if granted && granted[form]
      pool.uniq
    end

    #--- deserialize + normalize ----------------------------------------------
    # Hash -> freshly built, normalized Pokemon (battle copy). Assumes validate_h
    # already passed; still guards against bad data. `owner = nil` => anonymous.
    def h_to_pokemon(h, ruleset = ARNet.default_ruleset)
      level   = (ruleset["level_cap"] || 50)
      iv_flat = ruleset["iv_flat"]   # nil => keep transmitted IVs (clamped)
      species = h["species"].to_sym

      pkmn = Pokemon.new(species, level, nil, false, false)  # withMoves=false, recheck_form=false
      pkmn.form_simple = h["form"] if h["form"].is_a?(Integer) && h["form"] > 0
      pkmn.gender = h["gender"]    if [0, 1].include?(h["gender"])
      pkmn.shiny  = !!h["shiny"]
      pkmn.ability = h["ability"].to_sym if h["ability"] && !h["ability"].to_s.empty?
      pkmn.nature  = h["nature"].to_sym  if h["nature"]  && !h["nature"].to_s.empty?
      pkmn.item    = (h["item"] && !h["item"].to_s.empty?) ? h["item"].to_sym : nil

      mv = []
      (h["moves"] || []).each do |m|
        next unless m.is_a?(Hash) && m["id"] && GameData::Move.exists?(m["id"].to_sym)
        mo = Pokemon::Move.new(m["id"].to_sym)
        mo.ppup = (m["ppup"] || 0).to_i.clamp(0, 3)
        mo.pp   = mo.total_pp     # battles begin at full PP
        mv << mo
      end
      pkmn.moves = mv unless mv.empty?

      # IV/EV — level & IV are FORCED (anti-cheat); transmitted values ignored for IV.
      stat_ids.each do |sid|
        pkmn.iv[sid] = iv_flat ? iv_flat : (h.dig("iv", sid.to_s) || 0).to_i.clamp(0, Pokemon::IV_STAT_LIMIT)
        pkmn.ev[sid] = (h.dig("ev", sid.to_s) || 0).to_i.clamp(0, ONLINE_EV_STAT_LIMIT)
      end

      pkmn.happiness = (h["happiness"] || 70).to_i.clamp(0, 255)
      pkmn.poke_ball = h["ball"].to_sym if h["ball"] && GameData::Item.exists?(h["ball"].to_sym)

      # DBK extras (guarded — no-op if plugins absent)
      if h["tera_type"] && pkmn.respond_to?(:tera_type=) && GameData::Type.exists?(h["tera_type"].to_sym)
        pkmn.tera_type = h["tera_type"].to_sym
      end
      pkmn.gmax_factor = !!h["gmax"]       if h.key?("gmax") && pkmn.respond_to?(:gmax_factor=)
      pkmn.dynamax_lvl = h["dynamax_lvl"]  if h["dynamax_lvl"] && pkmn.respond_to?(:dynamax_lvl=)

      pkmn.calc_stats
      pkmn
    end

    # Array<Hash> -> [ok(bool), Array<Pokemon> | reason(String)]
    # Validates every entry first; rebuilds only if the whole team is legal.
    def data_to_party(arr, ruleset = ARNet.default_ruleset)
      return [false, "not an array"] unless arr.is_a?(Array)
      return [false, "empty team"] if arr.empty?
      return [false, "team too large"] if arr.length > 6
      arr.each_with_index do |h, i|
        ok, why = validate_h(h, ruleset)
        return [false, "mon #{i + 1}: #{why}"] unless ok
      end
      why = team_clause_violation(arr, ruleset)
      return [false, why] if why
      party = arr.map { |h| h_to_pokemon(h, ruleset) }
      [true, party]
    end
  end
end
