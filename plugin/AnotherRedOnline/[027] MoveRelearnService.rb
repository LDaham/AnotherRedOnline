#===============================================================================
# Another Red Online — 부가 서비스 "기술 배우기(떠올리기)" 간소화
#
# 포켓몬 센터 부가 서비스 NPC의 "기술 배우기/기술 떠올리기" 메뉴는 원래 맵 이벤트
# 커맨드로 다음을 물었다:
#   (1) "…기술을 가르칠까요?"           초기 네/아니오 확인
#   (2) 포켓몬 선택 창에서 B(취소)      → "…배울 수 있는 기술이 없네요…" 후 재선택
#   (3) "[포켓몬]에게 어떤 기술을…"      선택 후 안내 텍스트
#   (4) "[기술]을 가르치시겠습니까?"     스톡 pbRelearnMoveScreen 의 확인
#   (5) 기술 4개↑: "이미 4개 알고 있다" + "[포켓몬]이 [기술] 배울까요?" 확인
#   (6) 나갈 때 "…배우지 않겠…?" 확인
#
# tools/patch_maps.py 가 그 메뉴 분기(모든 센터 맵, 라벨 "기술 떠올리기"/"기술 배우기")
# 본문을 전부 지우고 이 파일의 전역 메서드 `pbMoveRelearnService` 한 줄 호출로 바꾼다.
# 여기서는 위 확인/안내를 전부 생략하고 곧바로 진행하는 무확인 플로우를 제공한다:
#   - 포켓몬 선택 → B 취소는 그냥 메뉴를 빠져나온다(안내 텍스트 없음).
#   - 선택 즉시 기술 목록으로 이동(안내 없음).
#   - 기술 선택 즉시 학습("가르치시겠습니까?" 없음).
#   - 기술이 4개면 곧장 삭제할 기술 선택 창(pbForgetMove)으로 이동("이미 4개"·"배울까요"
#     확인 없음). 삭제 창에서 취소하면 조용히 목록으로 돌아온다("포기할까?" 없음).
#
# 오프라인 편의 기능 — 온라인 결정론과 무관(대전 중 호출되지 않음). 학습 가능한 기술
# 목록은 12_Ultimate Move Tutor 가 오버라이드한 MoveRelearnerScreen#pbGetRelearnableMoves
# 를 그대로 재사용한다. [[convenience-patches]] [[ev-training-and-map-patch]]
#===============================================================================
module ARNet
  module_function

  # 무확인 학습. 4개 미만이면 즉시 습득, 4개면 곧바로 삭제 창으로. 확인 프롬프트 없음.
  # 반환: 학습 성공 여부(삭제 창 취소 시 false — 조용히 목록으로 복귀).
  def relearn_quick_learn(pkmn, move)
    mid = (GameData::Move.try_get(move).id rescue nil)
    return false unless mid
    return false if pkmn.hasMove?(mid)
    pkmn_name = pkmn.name
    move_name = GameData::Move.get(mid).name
    if pkmn.numMoves < Pokemon::MAX_MOVES
      pkmn.learn_move(mid)
      pbMessage("\\se[]" + _INTL("\\j[{1},은,는] \\j[{2},을,를] 배웠다!", pkmn_name, move_name) +
                "\\se[Pkmn move learnt]")
      return true
    end
    # 기술 4개: 곧바로 삭제할 기술 선택 창으로(확인 텍스트 생략).
    idx = pbForgetMove(pkmn, mid)
    return false if idx < 0                          # 삭제 창 취소 → 조용히 복귀
    old_name = pkmn.moves[idx].name
    pkmn.moves[idx] = Pokemon::Move.new(mid)
    pbMessage(_INTL("\\j[{1},은,는] \\j[{2},을,를] 잊었다! \\n그리고...", pkmn_name, old_name) + "\1")
    pbMessage("\\se[]" + _INTL("\\j[{1},은,는] \\j[{2},을,를] 배웠다!!", pkmn_name, move_name) +
              "\\se[Pkmn move learnt]")
    true
  end

  # 한 마리에 대한 무확인 기술 목록 → 선택 즉시 학습. 목록에서 취소하면 조용히 종료.
  # 기술 목록 정렬용 타입 순서(한국어 도감/기술 표기 순).
  RELEARN_TYPE_ORDER = [
    :NORMAL, :FIRE, :WATER, :GRASS, :ELECTRIC, :ICE, :FIGHTING, :POISON,
    :GROUND, :FLYING, :PSYCHIC, :BUG, :ROCK, :GHOST, :DRAGON, :DARK, :STEEL, :FAIRY
  ]

  # 학습 가능 기술 목록(기술 ID 배열)을 타입 순서로 정렬한다. 같은 타입 안에서는
  # 기술 이름(가나다)으로 2차 정렬해 안정적인 순서를 만든다. 목록에 없는 타입(예:
  # 무속성/커스텀)은 맨 뒤로 보낸다.
  def arnet_sort_relearn_moves(moves)
    moves.sort_by do |mid|
      data = GameData::Move.get(mid)
      ti = RELEARN_TYPE_ORDER.index(data.type)
      ti = RELEARN_TYPE_ORDER.length if ti.nil?
      [ti, data.name]
    end
  end

  def relearn_pokemon(pkmn)
    scene  = MoveRelearner_Scene.new
    screen = MoveRelearnerScreen.new(scene)
    moves  = screen.pbGetRelearnableMoves(pkmn)
    if moves.empty?
      pbMessage(_INTL("\\j[{1},은,는] 배울 수 있는 기술이 없어요.", pkmn.name))
      return
    end
    moves = arnet_sort_relearn_moves(moves)      # 타입 순으로 정렬해 표시
    scene.pbStartScene(pkmn, moves)
    loop do
      move = scene.pbChooseMove
      if move.nil?
        scene.pbEndScene                             # 취소 → 안내 없이 종료
        return
      end
      if relearn_quick_learn(pkmn, move)
        scene.pbEndScene
        return
      end
      # 삭제 창 취소 등으로 미학습 → 목록 유지, 다시 선택 가능
    end
  end
end

# 맵 이벤트의 Script 커맨드가 호출하는 진입점(전역). 확인/안내 없이 곧바로 진행.
def pbMoveRelearnService
  return if !$player || $player.party.nil? || $player.party.empty?
  pbFadeOutIn do
    scene  = PokemonParty_Scene.new
    screen = PokemonPartyScreen.new(scene, $player.party)
    screen.pbStartScene(_INTL("어느 포켓몬에게 기술을 가르칠까요?"), false)
    loop do
      idx = screen.pbChoosePokemon
      break if idx < 0                               # B(취소) → 안내 없이 메뉴 종료
      pkmn = $player.party[idx]
      next if pkmn.nil?
      if pkmn.egg?
        pbMessage(_INTL("알은 기술을 배울 수 없어요."))
        next
      end
      ARNet.relearn_pokemon(pkmn)
    end
    screen.pbEndScene
  end
end
