#===============================================================================
# Another Red Online — Enhanced Battle UI perspective flip for the guest ([023])
#
# DBK's "Enhanced Battle UI" adds a battler-info overlay (opened with the JUMPUP /
# "special" key: Scene#pbToggleBattleInfo -> pbSelectBattlerInfo -> pbOpenBattlerInfo).
# That whole overlay is drawn from the CANONICAL perspective (side 0 = "your side",
# bottom row; side 1 = "opponent", top row) using opposes? / pbOwnedByPlayer? /
# allSameSideBattlers / allOtherSideBattlers / @battle.player / @battle.opponent.
#
# In our online battles BOTH peers simulate the same canonical battle (side0 = host,
# side1 = guest) and only the GUEST flips the *presentation* ([012] BattleMirror).
# But [012] flips the main battle scene sprites, NOT this z=300 overlay — so on the
# guest the overlay stays host-oriented: the guest's own team (side1) is drawn in
# the "opponent" (top) slot and the host (side0) in the "your side" (bottom) slot.
# Result: the guest opens the info window, inspects the top ("opponent") slot, and
# sees their OWN Pokémon instead of the host's. (The host is correct.)
#
# Fix: when $arnet_view_flip is set (guest only), re-define the overlay's drawing/
# selection methods so the LOCAL viewer's own side is the bottom row and the foe is
# the top row — matching the flipped main view. This is PURE PRESENTATION on the
# guest: it never touches the lockstep simulation or checksum, so it is safe.
#
# Every override falls through to the original (aliased) DBK method unless flipped,
# so single-player and the host use the untouched code path (no regression risk).
# Only the four canonical data sources are swapped for the viewer; all positional /
# drawing code is copied verbatim from DBK's [20] Enhanced Battle UI [002]/[003].
#===============================================================================
if defined?(Battle::Scene) && Battle::Scene.method_defined?(:pbUpdateBattlerInfo)
  class Battle::Scene
    #---------------------------------------------------------------------------
    # Viewer-relative perspective helpers.
    #
    # near = the canonical battle side that belongs to the LOCAL viewer (drawn on
    # the bottom "your side" row); far = the opposing side (top row). On the host
    # these are 0/1 (unchanged); on the guest they are 1/0.
    #---------------------------------------------------------------------------
    def arnet_near_side
      $arnet_view_flip ? 1 : 0
    end

    # Battlers on the viewer's own / opposing side, using the exact same engine
    # accessors DBK uses (identical fainted/ordering semantics) but seeded from the
    # viewer's side index so the set flips with the perspective.
    def arnet_near_battlers
      @battle.allSameSideBattlers(arnet_near_side)
    end

    def arnet_far_battlers
      @battle.allOtherSideBattlers(arnet_near_side)
    end

    # Trainers whose party-ball lineups belong to the viewer's own / opposing side.
    def arnet_near_trainers
      $arnet_view_flip ? @battle.opponent : @battle.player
    end

    def arnet_far_trainers
      $arnet_view_flip ? @battle.player : @battle.opponent
    end

    # Is this battler the LOCAL viewer's opponent? (governs displayPokemon vs the
    # real pokemon, i.e. Illusion hiding). Reuses [012]'s canonical helper.
    def arnet_local_foe?(b)
      ARNet.pres_far?(b)
    end

    # Is this battler owned by the LOCAL viewer? (governs the full-vs-limited info
    # panel). On the host this is the engine's pbOwnedByPlayer?; on the guest the
    # viewer owns the opposing (side 1) team, so use opposes?.
    def arnet_local_mine?(b)
      $arnet_view_flip ? b.opposes? : b.pbOwnedByPlayer?
    end

    #---------------------------------------------------------------------------
    # Icons on the selection menu — flip which pokemon (real vs display) is shown.
    #---------------------------------------------------------------------------
    unless method_defined?(:arnet_ebui_orig_pbUpdateBattlerIcons)
      alias_method :arnet_ebui_orig_pbUpdateBattlerIcons, :pbUpdateBattlerIcons
    end
    def pbUpdateBattlerIcons
      return arnet_ebui_orig_pbUpdateBattlerIcons unless $arnet_view_flip
      @battle.allBattlers.each do |b|
        next if !b
        poke = arnet_local_foe?(b) ? b.displayPokemon : b.pokemon
        if !b.fainted?
          @sprites["info_icon#{b.index}"].pokemon = poke
          @sprites["info_icon#{b.index}"].visible = @enhancedUIToggle == :battler
          @sprites["info_icon#{b.index}"].setOffset(PictureOrigin::CENTER)
          if b.shadowPokemon?
            @sprites["info_icon#{b.index}"].set_shadow_icon_pattern
          elsif b.dynamax?
            @sprites["info_icon#{b.index}"].set_dynamax_icon_pattern
            color = (b.isSpecies?(:CALYREX)) ? Color.new(36, 243, 243) : Color.new(250, 57, 96)
          elsif b.tera?
            @sprites["info_icon#{b.index}"].set_tera_icon_pattern
          else
            @sprites["info_icon#{b.index}"].zoom_x = 1
            @sprites["info_icon#{b.index}"].zoom_y = 1
            @sprites["info_icon#{b.index}"].pattern = nil
          end
        else
          @sprites["info_icon#{b.index}"].visible = false
        end
        pbUpdateOutline("info_icon#{b.index}", poke)
        pbColorOutline("info_icon#{b.index}", color)
        pbShowOutline("info_icon#{b.index}", false)
      end
    end

    #---------------------------------------------------------------------------
    # Selection menu layout — swap which canonical side fills the bottom/top row.
    # Copied verbatim from DBK [002] pbUpdateBattlerSelection with only the four
    # canonical data sources routed through the viewer-relative helpers.
    #---------------------------------------------------------------------------
    unless method_defined?(:arnet_ebui_orig_pbUpdateBattlerSelection)
      alias_method :arnet_ebui_orig_pbUpdateBattlerSelection, :pbUpdateBattlerSelection
    end
    def pbUpdateBattlerSelection(idxSide, idxPoke, select = false)
      return arnet_ebui_orig_pbUpdateBattlerSelection(idxSide, idxPoke, select) unless $arnet_view_flip
      @enhancedUIOverlay.clear
      return if @enhancedUIToggle != :battler
      ypos = 68
      textPos = []
      imagePos = [[@path + "select_bg", 0, ypos]]
      2.times do |side|
        trainers = []
        count = @battle.pbSideBattlerCount(side)
        case side
        #-----------------------------------------------------------------------
        # Viewer's own side (bottom row).
        #-----------------------------------------------------------------------
        when 0
          arnet_near_battlers.each_with_index do |b, i|
            case count
            when 1 then iconX, bgX = 202, 173
            when 2 then iconX, bgX = 96 + (208 * i), 68 + (208 * i)
            when 3 then iconX, bgX = 32 + (168 * i), 4 + (169 * i)
            end
            iconY = ypos + 114
            nameX = iconX + 82
            if idxSide == side && idxPoke == i
              base, shadow = BASE_LIGHT, SHADOW_LIGHT
              if b.dynamax?
                shadow = (b.isSpecies?(:CALYREX)) ? Color.new(48, 206, 216) : Color.new(248, 32, 32)
              end
              imagePos.push([@path + "select_cursor", bgX, iconY - 28, 0, 52, 166, 52])
            else
              base, shadow = BASE_DARK, SHADOW_DARK
              imagePos.push([@path + "select_cursor", bgX, iconY - 28, 0, 0, 166, 52])
            end
            @sprites["info_icon#{b.index}"].x = iconX
            @sprites["info_icon#{b.index}"].y = iconY
            pbSetWithOutline("info_icon#{b.index}", [iconX, iconY, 300])
            imagePos.push([@path + "info_owner", bgX + 36, iconY + 12, 0, 0, 128, 20],
                          [@path + "info_gender", bgX + 148, iconY - 34, b.gender * 22, 0, 22, 22])
            textPos.push([_INTL("{1}", b.pokemon.name), nameX, iconY - 16, :center, base, shadow],
                         [@battle.pbGetOwnerFromBattlerIndex(b.index).name, nameX - 10, iconY + 14, 2, BASE_LIGHT, SHADOW_LIGHT])
          end
          if arnet_near_trainers
            arnet_near_trainers.each_with_index { |t, i| trainers.push([t, i]) if t.able_pokemon_count > 0 }
          end
          ballY = ypos + 154
          ballXFirst = 35
          ballXLast = Graphics.width - (16 * NUM_BALLS) - 35
          ballOffset = 2
        #-----------------------------------------------------------------------
        # Viewer's opponent side (top row).
        #-----------------------------------------------------------------------
        when 1
          arnet_far_battlers.reverse.each_with_index do |b, i|
            case count
            when 1 then iconX, bgX = 202, 173
            when 2 then iconX, bgX = 96 + (208 * i), 68 + (208 * i)
            when 3 then iconX, bgX = 32 + (168 * i), 4 + (169 * i)
            end
            iconY = ypos + 38
            nameX = iconX + 82
            if idxSide == side && idxPoke == i
              base, shadow = BASE_LIGHT, SHADOW_LIGHT
              if b.dynamax?
                shadow = (b.isSpecies?(:CALYREX)) ? Color.new(48, 206, 216) : Color.new(248, 32, 32)
              end
              imagePos.push([@path + "select_cursor", bgX, iconY - 28, 0, 52, 166, 52])
            else
              base, shadow = BASE_DARK, SHADOW_DARK
              imagePos.push([@path + "select_cursor", bgX, iconY - 28, 0, 0, 166, 52])
            end
            @sprites["info_icon#{b.index}"].x = iconX
            @sprites["info_icon#{b.index}"].y = iconY
            pbSetWithOutline("info_icon#{b.index}", [iconX, iconY, 400])
            textPos.push([_INTL("{1}", b.displayPokemon.name), nameX, iconY - 16, :center, base, shadow])
            if @battle.trainerBattle?
              imagePos.push([@path + "info_owner", bgX + 36, iconY + 12, 0, 0, 128, 20])
              textPos.push([@battle.pbGetOwnerFromBattlerIndex(b.index).name, nameX - 10, iconY + 14, :center, BASE_LIGHT, SHADOW_LIGHT])
            end
            imagePos.push([@path + "info_gender", bgX + 148, iconY - 36, b.displayPokemon.gender * 22, 0, 22, 22]) if !b.isRaidBoss?
          end
          if arnet_far_trainers
            arnet_far_trainers.each_with_index { |t, i| trainers.push([t, i]) if t.able_pokemon_count > 0 }
            ballY = ypos - 17
            ballXFirst = Graphics.width - (16 * NUM_BALLS) - 35
            ballXLast = 35
            ballOffset = 3
          end
        end
        #---------------------------------------------------------------------
        # Draws party ball lineups.
        #---------------------------------------------------------------------
        if !trainers.empty?
          ballXMiddle = (Graphics.width / 2) - 48
          ballX = ballXMiddle
          trainers.each do |array|
            trainer, idxTrainer = *array
            if trainers.length > 1
              case trainer
              when trainers.first[0] then ballX = ballXFirst
              when trainers.last[0]  then ballX = ballXLast
              else                        ballX = ballXMiddle
              end
            end
            imagePos.push([@path + "info_owner", ballX - 16, ballY - ballOffset, 0, 0, 128, 20])
            NUM_BALLS.times do |slot|
              idx = 0
              if !trainer.party[slot]                   then idx = 3 # Empty
              elsif !trainer.party[slot].able?          then idx = 2 # Fainted
              elsif trainer.party[slot].status != :NONE then idx = 1 # Status
              end
              imagePos.push([@path + "info_party", ballX + (slot * 16), ballY, idx * 15, 0, 15, 15])
            end
            # Draws each trainer's Wonder Launcher points.
            if @battle.launcherBattle?
              path = Settings::WONDER_LAUNCHER_PATH
              maxPoints = Settings::WONDER_LAUNCHER_MAX_POINTS
              points = @battle.launcherPoints[side][idxTrainer]
              x = ballX - 16 + ((128 - (10 * maxPoints + 2)) / 2).floor
              y = (side == 0) ? ballY + 18 : ballY - 17
              maxPoints.times do |i|
                imagePos.push([path + "points", x + 10 * i, y, 0, 0, 12, 14])
                imagePos.push([path + "points", x + 10 * i, y, 12, 0, 12, 14]) if points >= i + 1
              end
            end
          end
        end
      end
      pbUpdateBattlerIcons
      pbDrawImagePositions(@enhancedUIOverlay, imagePos)
      pbDrawTextPositions(@enhancedUIOverlay, textPos)
      pbSelectBattlerInfo if select
    end

    #---------------------------------------------------------------------------
    # Selection controls — build the battlers array from the viewer's perspective
    # so idxSide 0 = own (bottom), 1 = foe (top), matching the flipped layout.
    #---------------------------------------------------------------------------
    unless method_defined?(:arnet_ebui_orig_pbSelectBattlerInfo)
      alias_method :arnet_ebui_orig_pbSelectBattlerInfo, :pbSelectBattlerInfo
    end
    def pbSelectBattlerInfo
      return arnet_ebui_orig_pbSelectBattlerInfo unless $arnet_view_flip
      return if @enhancedUIToggle != :battler
      pbHideUIPrompt
      idxSide = 0
      idxPoke = (@battle.pbSideBattlerCount(arnet_near_side) < 3) ? 0 : 1
      battlers = [[], []]
      arnet_near_battlers.each { |b| battlers[0].push(b) }
      arnet_far_battlers.reverse.each { |b| battlers[1].push(b) }
      battler = battlers[idxSide][idxPoke]
      idxBattler = @sprites["enhancedUIPrompts"].battler
      pbShowOutline("info_icon#{battler.index}")
      cw = @sprites["fightWindow"]
      switchUI = 0
      loop do
        pbUpdate(cw)
        pbUpdateInfoSprites
        oldSide = idxSide
        oldPoke = idxPoke
        break if Input.trigger?(Input::BACK) || Input.trigger?(Input::JUMPUP)
        if Input.trigger?(Input::USE)
          pbPlayDecisionSE
          ret = pbOpenBattlerInfo(battler, battlers)
          case ret
          when Array
            idxSide, idxPoke = ret[0], ret[1]
            battler = battlers[idxSide][idxPoke]
            pbUpdateBattlerSelection(idxSide, idxPoke)
            pbShowOutline("info_icon#{battler.index}")
          when Numeric
            switchUI = ret
            break
          when nil then break
          end
        elsif Input.trigger?(Input::LEFT) && @battle.pbSideBattlerCount(idxSide) > 1
          idxPoke -= 1
          idxPoke = @battle.pbSideBattlerCount(idxSide) - 1 if idxPoke < 0
          pbPlayCursorSE
        elsif Input.trigger?(Input::RIGHT) && @battle.pbSideBattlerCount(idxSide) > 1
          idxPoke += 1
          idxPoke = 0 if idxPoke > @battle.pbSideBattlerCount(idxSide) - 1
          pbPlayCursorSE
        elsif Input.trigger?(Input::UP) || Input.trigger?(Input::DOWN)
          idxSide = (idxSide == 0) ? 1 : 0
          if idxPoke > @battle.pbSideBattlerCount(idxSide) - 1
            until idxPoke == @battle.pbSideBattlerCount(idxSide) - 1
              idxPoke -= 1
            end
          end
          pbPlayCursorSE
        elsif Input.trigger?(Input::JUMPDOWN)
          if cw.visible
            switchUI = 1
            break
          elsif @battle.pbCanUsePokeBall?(idxBattler)
            switchUI = 2
            break
          end
        end
        if oldSide != idxSide || oldPoke != idxPoke
          pbUpdateBattlerSelection(idxSide, idxPoke)
          battler = battlers[idxSide][idxPoke]
          @battle.allBattlers.each do |b|
            showOutline = b.index == battler.index
            pbShowOutline("info_icon#{b.index}", showOutline)
          end
        end
      end
      pbHideInfoUI
      pbUpdateBattlerIcons
      case switchUI
      when 0 then pbPlayCloseMenuSE; pbRefreshUIPrompt
      when 1 then pbToggleMoveInfo(cw.battler, :none, cw)
      when 2 then pbToggleBallInfo(idxBattler)
      end
    end

    #---------------------------------------------------------------------------
    # Detail window controls — only the return-index block (which slot to re-select
    # afterwards) is perspective-dependent; keep it consistent with the flipped
    # battlers array (0 = own/bottom, 1 = foe/top).
    #---------------------------------------------------------------------------
    unless method_defined?(:arnet_ebui_orig_pbOpenBattlerInfo)
      alias_method :arnet_ebui_orig_pbOpenBattlerInfo, :pbOpenBattlerInfo
    end
    def pbOpenBattlerInfo(battler, battlers)
      return arnet_ebui_orig_pbOpenBattlerInfo(battler, battlers) unless $arnet_view_flip
      return if @enhancedUIToggle != :battler
      ret = nil
      idx = 0
      battlerTotal = battlers.flatten
      for i in 0...battlerTotal.length
        idx = i if battler == battlerTotal[i]
      end
      maxSize = battlerTotal.length - 1
      idxEffect = 0
      effects = pbGetDisplayEffects(battler)
      effctSize = effects.length - 1
      pbUpdateBattlerInfo(battler, effects, idxEffect)
      cw = @sprites["fightWindow"]
      @sprites["leftarrow"].x = -2
      @sprites["leftarrow"].y = 71
      @sprites["leftarrow"].visible = true
      @sprites["rightarrow"].x = Graphics.width - 38
      @sprites["rightarrow"].y = 71
      @sprites["rightarrow"].visible = true
      loop do
        pbUpdate(cw)
        pbUpdateInfoSprites
        break if Input.trigger?(Input::BACK)
        if Input.trigger?(Input::LEFT)
          idx -= 1
          idx = maxSize if idx < 0
          doFullRefresh = true
        elsif Input.trigger?(Input::RIGHT)
          idx += 1
          idx = 0 if idx > maxSize
          doFullRefresh = true
        elsif Input.repeat?(Input::UP) && effects.length > 1
          idxEffect -= 1
          idxEffect = effctSize if idxEffect < 0
          doRefresh = true
        elsif	Input.repeat?(Input::DOWN) && effects.length > 1
          idxEffect += 1
          idxEffect = 0 if idxEffect > effctSize
          doRefresh = true
        elsif Input.trigger?(Input::JUMPDOWN)
          if cw.visible
            ret = 1
            break
          elsif @battle.pbCanUsePokeBall?(@sprites["enhancedUIPrompts"].battler)
            ret = 2
            break
          end
        elsif Input.trigger?(Input::JUMPUP) || Input.trigger?(Input::USE)
          ret = []
          if arnet_local_mine?(battler)
            ret.push(0)
            arnet_near_battlers.each_with_index do |b, i|
              next if b.index != battler.index
              ret.push(i)
            end
          else
            ret.push(1)
            arnet_far_battlers.reverse.each_with_index do |b, i|
              next if b.index != battler.index
              ret.push(i)
            end
          end
          pbPlayDecisionSE
          break
        end
        if doFullRefresh
          battler = battlerTotal[idx]
          effects = pbGetDisplayEffects(battler)
          effctSize = effects.length - 1
          idxEffect = 0
          doRefresh = true
        end
        if doRefresh
          pbPlayCursorSE
          pbUpdateBattlerInfo(battler, effects, idxEffect)
          doRefresh = false
          doFullRefresh = false
        end
      end
      @sprites["leftarrow"].visible = false
      @sprites["rightarrow"].visible = false
      return ret
    end

    #---------------------------------------------------------------------------
    # Detail window content — flip which pokemon is shown (real vs display) and
    # whether the full owner panel is drawn.
    #---------------------------------------------------------------------------
    unless method_defined?(:arnet_ebui_orig_pbUpdateBattlerInfo)
      alias_method :arnet_ebui_orig_pbUpdateBattlerInfo, :pbUpdateBattlerInfo
    end
    def pbUpdateBattlerInfo(battler, effects, idxEffect = 0)
      return arnet_ebui_orig_pbUpdateBattlerInfo(battler, effects, idxEffect) unless $arnet_view_flip
      @enhancedUIOverlay.clear
      pbUpdateBattlerIcons
      return if @enhancedUIToggle != :battler
      xpos = 28
      ypos = 24
      iconX = xpos + 28
      iconY = ypos + 62
      panelX = xpos + 240
      #-------------------------------------------------------------------------
      # General UI elements.
      poke = arnet_local_foe?(battler) ? battler.displayPokemon : battler.pokemon
      level = (battler.isRaidBoss?) ? "???" : battler.level.to_s
      movename = (battler.lastMoveUsed) ? GameData::Move.get(battler.lastMoveUsed).name : "---"
      movename = movename[0..12] + "..." if movename.length > 16
      imagePos = [
        [@path + "info_bg", 0, 0],
        [@path + "info_bg_data", 0, 0],
        [@path + "info_level", xpos + 16, ypos + 106]
      ]
      imagePos.push([@path + "info_gender", xpos + 148, ypos + 22, poke.gender * 22, 0, 22, 22]) if !battler.isRaidBoss?
      textPos  = [
        [_INTL("{1}", poke.name), iconX + 82, iconY - 20, :center, BASE_DARK, SHADOW_DARK],
        [_INTL("{1}", level), xpos + 38, ypos + 104, :left, BASE_LIGHT, SHADOW_LIGHT],
        [_INTL("Used: {1}", movename), xpos + 349, ypos + 104, :center, BASE_LIGHT, SHADOW_LIGHT],
        [_INTL("Turn {1}", @battle.turnCount + 1), Graphics.width - xpos - 32, ypos + 8, :center, BASE_DARK, SHADOW_DARK]
      ]
      #-------------------------------------------------------------------------
      # Battler icon.
      @battle.allBattlers.each do |b|
        @sprites["info_icon#{b.index}"].x = iconX
        @sprites["info_icon#{b.index}"].y = iconY
        @sprites["info_icon#{b.index}"].visible = (b.index == battler.index)
      end
      #-------------------------------------------------------------------------
      # Owner
      if !battler.wild?
        imagePos.push([@path + "info_owner", xpos - 34, ypos + 6, 0, 20, 128, 20])
        textPos.push([@battle.pbGetOwnerFromBattlerIndex(battler.index).name, xpos + 32, ypos + 8, :center, BASE_DARK, SHADOW_DARK])
      end
      # Battler HP.
      if battler.hp > 0
        w = battler.hp * 96 / battler.totalhp.to_f
        w = 1 if w < 1
        w = ((w / 2).round) * 2
        hpzone = 0
        hpzone = 1 if battler.hp <= (battler.totalhp / 2).floor
        hpzone = 2 if battler.hp <= (battler.totalhp / 4).floor
        imagePos.push([@path + "info_hp", 86, 86, 0, hpzone * 6, w, 6])
      end
      # Battler status.
      if battler.status != :NONE
        iconPos = GameData::Status.get(battler.status).icon_position
        imagePos.push(["Graphics/UI/statuses", xpos + 86, ypos + 104, 0, iconPos * 16, 44, 16])
      end
      # Shininess
      imagePos.push(["Graphics/UI/shiny", xpos + 142, ypos + 102]) if poke.shiny?
      #-------------------------------------------------------------------------
      # Battler info for viewer-owned Pokemon.
      if arnet_local_mine?(battler)
        imagePos.push(
          [@path + "info_owner", xpos + 36, iconY + 10, 0, 0, 128, 20],
          [@path + "info_cursor", panelX, 62, 0, 0, 218, 26],
          [@path + "info_cursor", panelX, 86, 0, 0, 218, 26]
        )
        textPos.push(
          [_INTL("Abil."), xpos + 272, ypos + 44, :center, BASE_LIGHT, SHADOW_LIGHT],
          [_INTL("Item"), xpos + 272, ypos + 68, :center, BASE_LIGHT, SHADOW_LIGHT],
          [_INTL("{1}", battler.abilityName), xpos + 376, ypos + 44, :center, BASE_DARK, SHADOW_DARK],
          [_INTL("{1}", battler.itemName), xpos + 376, ypos + 68, :center, BASE_DARK, SHADOW_DARK],
          [sprintf("%d/%d", battler.hp, battler.totalhp), iconX + 74, iconY + 12, :center, BASE_LIGHT, SHADOW_LIGHT]
        )
      end
      #-------------------------------------------------------------------------
      pbAddWildIconDisplay(xpos, ypos, battler, imagePos)
      pbAddStatsDisplay(xpos, ypos, battler, imagePos, textPos)
      pbDrawImagePositions(@enhancedUIOverlay, imagePos)
      pbDrawTextPositions(@enhancedUIOverlay, textPos)
      pbAddTypesDisplay(xpos, ypos, battler, poke)
      pbAddEffectsDisplay(xpos, ypos, panelX, effects, idxEffect)
    end

    #---------------------------------------------------------------------------
    # Stats panel — nature colouring is only shown for viewer-owned Pokemon.
    #---------------------------------------------------------------------------
    unless method_defined?(:arnet_ebui_orig_pbAddStatsDisplay)
      alias_method :arnet_ebui_orig_pbAddStatsDisplay, :pbAddStatsDisplay
    end
    def pbAddStatsDisplay(xpos, ypos, battler, imagePos, textPos)
      return arnet_ebui_orig_pbAddStatsDisplay(xpos, ypos, battler, imagePos, textPos) unless $arnet_view_flip
      [[:ATTACK,          _INTL("Attack")],
       [:DEFENSE,         _INTL("Defense")],
       [:SPECIAL_ATTACK,  _INTL("Sp. Atk")],
       [:SPECIAL_DEFENSE, _INTL("Sp. Def")],
       [:SPEED,           _INTL("Speed")],
       [:ACCURACY,        _INTL("Accuracy")],
       [:EVASION,         _INTL("Evasion")],
       _INTL("Crit. Hit")
      ].each_with_index do |stat, i|
        if stat.is_a?(Array)
          color = SHADOW_LIGHT
          if arnet_local_mine?(battler)
            battler.pokemon.nature_for_stats.stat_changes.each do |s|
              if stat[0] == s[0]
                color = Color.new(136, 96, 72)  if s[1] > 0 # Red Nature text.
                color = Color.new(64, 120, 152) if s[1] < 0 # Blue Nature text.
              end
            end
          end
          textPos.push([stat[1], xpos + 16, ypos + 138 + (i * 24), :left, BASE_LIGHT, color])
          stage = battler.stages[stat[0]]
        else
          textPos.push([stat, xpos + 16, ypos + 138 + (i * 24), :left, BASE_LIGHT, SHADOW_LIGHT])
          stage = [battler.effects[PBEffects::FocusEnergy], 3].min
        end
        if stage != 0
          arrow = (stage > 0) ? 0 : 18
          stage.abs.times do |t|
            imagePos.push([@path + "info_stats", xpos + 110 + (t * 18), ypos + 136 + (i * 24), arrow, 0, 18, 18])
          end
        end
      end
    end

    #---------------------------------------------------------------------------
    # Types panel — Illusion hiding / unknown-species / Tera gating are relative
    # to the viewer's ownership.
    #---------------------------------------------------------------------------
    unless method_defined?(:arnet_ebui_orig_pbAddTypesDisplay)
      alias_method :arnet_ebui_orig_pbAddTypesDisplay, :pbAddTypesDisplay
    end
    def pbAddTypesDisplay(xpos, ypos, battler, poke)
      return arnet_ebui_orig_pbAddTypesDisplay(xpos, ypos, battler, poke) unless $arnet_view_flip
      #-------------------------------------------------------------------------
      # Gets display types (considers Illusion)
      illusion = battler.effects[PBEffects::Illusion] && !arnet_local_mine?(battler)
      if battler.tera?
        displayTypes = (illusion) ? poke.types.clone : battler.pbPreTeraTypes
      elsif illusion
        displayTypes = poke.types.clone
        displayTypes.push(battler.effects[PBEffects::ExtraType]) if battler.effects[PBEffects::ExtraType]
      else
        displayTypes = battler.pbTypes(true)
      end
      #-------------------------------------------------------------------------
      # Displays the "???" type on newly encountered species, or battlers with no typing.
      if Settings::SHOW_TYPE_EFFECTIVENESS_FOR_NEW_SPECIES
        unknown_species = false
      else
        unknown_species = !(
          !@battle.internalBattle ||
          arnet_local_mine?(battler) ||
          $player.pokedex.owned?(poke.species) ||
          $player.pokedex.battled_count(poke.species) > 0
        )
      end
      displayTypes = [:QMARKS] if unknown_species || displayTypes.empty?
      #-------------------------------------------------------------------------
      # Draws each display type. Maximum of 3 types.
      typeY = (displayTypes.length >= 3) ? ypos + 6 : ypos + 34
      typebitmap = AnimatedBitmap.new(_INTL("Graphics/UI/types"))
      displayTypes.each_with_index do |type, i|
        break if i > 2
        type_number = GameData::Type.get(type).icon_position
        type_rect = Rect.new(0, type_number * 28, 64, 28)
        @enhancedUIOverlay.blt(xpos + 170, typeY + (i * 30), typebitmap.bitmap, type_rect)
      end
      #-------------------------------------------------------------------------
      # Draws Tera type.
      if battler.tera?
        showTera = true
      else
        showTera = defined?(battler.tera_type) && battler.pokemon.terastal_able?
        showTera = ((@battle.internalBattle) ? arnet_local_mine?(battler) : true) if showTera
      end
      if showTera
        pkmn = (illusion) ? poke : battler
        pbDrawImagePositions(@enhancedUIOverlay, [[@path + "info_extra", xpos + 182, ypos + 95]])
        pbDisplayTeraType(pkmn, @enhancedUIOverlay, xpos + 186, ypos + 97, true)
      end
    end
  end
end
