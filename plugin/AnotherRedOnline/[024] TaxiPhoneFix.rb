#===============================================================================
# Another Red Online — [024] Flying Taxi phone fix
#-------------------------------------------------------------------------------
# The "공중날기 택시" phone contact (Pokégear → Phone → 전화걸기) runs common event
# #3, which issues a raw "Transfer Player" ([201]) command straight to the chosen
# region's coordinates. command_201 sets $game_temp.player_transferring = true and
# calls Graphics.freeze, but the ACTUAL map transfer is only ever carried out by
# Scene_Map#update — and at that moment we are several modal loops deep:
#
#     pause menu  →  Pokégear scene  →  Phone screen  →  pbCommonEvent(3)
#
# pbCommonEvent finishes normally (command_201 returns false but only pauses one
# tick; the interpreter then runs out and stops), and the Phone screen closes
# itself via $game_temp.phone_force_close. BUT the Pokégear scene and the pause
# menu stay open on top of the now-frozen graphics, because:
#   • the :phone Pokégear handler always returns false  → Pokégear loop keeps going
#   • the :pokegear pause handler returns pbFlyToNewLocation, which is false here
#     (no fly_destination / no HM02) → pause-menu loop keeps going
# So the screen looks frozen and the player has to blindly back out of both menus
# ("B 연타") before Scene_Map finally performs the queued transfer.
#
# Fix: when a phone call has queued a transfer, tear the Pokégear and the pause
# menu down automatically so control returns to Scene_Map, which then performs the
# pending transfer (and its fade transition). We keep the taxi's own [201] intact
# — it works fine once we actually reach the map — and only repair the unwinding.
#
# This is purely overworld UI flow: no battle state, no RNG, no lockstep concern.
#
# Both handlers are re-registered verbatim from the base game (MenuHandlers.add
# overwrites by id, and this plugin loads last), adding ONLY the
# player_transferring handling. The Pokégear is opened from exactly one place
# (the pause menu), so these two are the only unwinding points.
#===============================================================================

# Pokégear → Phone: if the call queued a map transfer, close the Pokégear too
# (mirror the :map app, which disposes the scene and returns truthy to break the
# Pokégear command loop). Otherwise unchanged (returns false → menu stays open).
MenuHandlers.add(:pokegear_menu, :phone, {
  "name"      => _INTL("Phone"),
  "icon_name" => "phone",
  "order"     => 10,
  "effect"    => proc { |menu|
    pbFadeOutIn do
      scene = PokemonPhone_Scene.new
      screen = PokemonPhoneScreen.new(scene)
      screen.pbStartScreen
      if $game_temp.player_transferring
        menu.dispose
        next 99999
      end
    end
    next $game_temp.player_transferring
  }
})

# Pause menu → Pokégear: if a phone call queued a transfer, end the pause menu so
# Scene_Map takes over; otherwise keep the original Fly-destination /
# pbFlyToNewLocation behaviour exactly (region-map "Map" app fly still works).
MenuHandlers.add(:pause_menu, :pokegear, {
  "name"      => _INTL("Pokégear"),
  "order"     => 40,
  "condition" => proc { next $player.has_pokegear },
  "effect"    => proc { |menu|
    pbPlayDecisionSE
    pbFadeOutIn do
      scene = PokemonPokegear_Scene.new
      screen = PokemonPokegearScreen.new(scene)
      screen.pbStartScreen
      if $game_temp.fly_destination || $game_temp.player_transferring
        menu.pbEndScene
      else
        menu.pbRefresh
      end
    end
    next true if $game_temp.player_transferring   # taxi already queued the [201]
    next pbFlyToNewLocation
  }
})

#===============================================================================
# 스마트로토무 전화 탭 개선 (Another Red) — 두 가지:
#   (A) 공중날기 택시(아머까오, 커먼이벤트 #3) 컨트랙트를 항상 목록 최상단에 고정.
#       기존 정렬은 $PokemonGlobal.phone.contacts 배열 순서 그대로다(이름 / 트레이너
#       타입 / 특별한 만남 순 수동 정렬 메뉴로만 바뀜) — 즉 택시가 아래로 밀릴 수 있었다.
#       pbRefreshList가 목록을 다시 그릴 때마다 택시를 실제 컨트랙트 배열 맨 앞으로 당겨
#       핀 고정한다(수동 정렬 후에도 계속 최상단). 실제 배열을 재배치하므로 컨트랙트
#       이동(스위치) 기능의 인덱싱과도 어긋나지 않는다.
#   (B) NPC(트레이너) 통화 종료("전화가 끊어졌다") 후 전화 화면이 닫혀 로토무 홈 탭까지
#       나가던 것을, 전화 목록에 그대로 머무르도록 수정. 스톡 pbStartScreen은 통화 직후
#       무조건 phone_force_close=true 였다 — 이걸 "전송이 걸린 통화(=택시 워프)일 때만"
#       으로 바꾼다. 택시는 pbCommonEvent(3)이 player_transferring을 세팅하므로 그때만
#       화면을 닫고, 위 [201] 핸들러들이 워프를 마무리한다. 일반 NPC 통화는 전송이 없어
#       루프가 계속 → pbChooseContact로 되돌아가 전화 목록이 유지된다(스프라이트 생존).
#===============================================================================
class PokemonPhone_Scene
  ARNET_TAXI_COMMON_EVENT = 3 unless defined?(ARNET_TAXI_COMMON_EVENT)

  alias_method :arnet_taxi_orig_pbRefreshList, :pbRefreshList
  def pbRefreshList
    arnet_pin_taxi_contact_first
    arnet_taxi_orig_pbRefreshList
  end

  # 택시(비-트레이너 + 커먼이벤트 #3) 컨트랙트를 실제 배열 맨 앞으로 이동. 없으면 no-op.
  def arnet_pin_taxi_contact_first
    return unless $PokemonGlobal && $PokemonGlobal.phone
    list = $PokemonGlobal.phone.contacts
    return unless list.is_a?(Array)
    ti = list.index do |c|
      c && !c.trainer? && (c.common_event_id rescue nil) == ARNET_TAXI_COMMON_EVENT
    end
    return if ti.nil? || ti == 0
    list.insert(0, list.delete_at(ti))
  rescue Exception
  end
end

# pbStartScreen 전체 재정의(스톡 302_UI_Phone.rb verbatim, ★표시 한 줄만 변경).
class PokemonPhoneScreen
  def pbStartScreen
    if $PokemonGlobal.phone.contacts.none? { |con| con.visible? }
      pbMessage(_INTL("There are no phone numbers stored."))
      return
    end
    @scene.pbStartScene
    loop do
      break if $game_temp.phone_force_close
      contact = @scene.pbChooseContact
      break if !contact
      commands = []
      commands.push(_INTL("전화걸기"))
      commands.push(_INTL("정렬"))
      commands.push(_INTL("Cancel"))
      cmd = pbShowCommands(nil, commands, -1)
      cmd += 1 if cmd >= 1 && !contact.can_hide?
      case cmd
      when 0   # Call
        Phone::Call.make_outgoing(contact)
        # ★ 변경점: 전송이 걸린 통화(=아머까오 택시 워프)일 때만 전화 화면을 닫는다.
        # 일반 NPC 통화는 끝나도 전화 목록에 머무른다(로토무 홈 탭까지 안 나감).
        $game_temp.phone_force_close = true if $game_temp.player_transferring
      when 1   # Delete
        name = contact.display_name
        if pbConfirmMessage(_INTL("Are you sure you want to delete {1} from your phone?", name))
          contact.visible = false
          $PokemonGlobal.phone.sort_contacts
          @scene.pbRefreshList
          pbMessage(_INTL("{1} was deleted from your phone contacts.", name))
          if $PokemonGlobal.phone.contacts.none? { |con| con.visible? }
            pbMessage(_INTL("There are no phone numbers stored."))
            break
          end
        end
      when 2   # Sort Contacts
        case pbMessage(_INTL("어떤 순으로 정렬할까요?"),
                       [_INTL("이름"),
                        _INTL("트레이너 타입"),
                        _INTL("특별한 만남 순"),
                        _INTL("Cancel")], -1, nil, 0)
        when 0   # By name
          $PokemonGlobal.phone.contacts.sort! { |a, b| a.name <=> b.name }
          $PokemonGlobal.phone.sort_contacts
          @scene.pbRefreshList
        when 1   # By trainer type
          $PokemonGlobal.phone.contacts.sort! { |a, b| a.display_name <=> b.display_name }
          $PokemonGlobal.phone.sort_contacts
          @scene.pbRefreshList
        when 2   # Special contacts first
          new_contacts = []
          2.times do |i|
            $PokemonGlobal.phone.contacts.each do |con|
              next if (i == 0 && con.trainer?) || (i == 1 && !con.trainer?)
              new_contacts.push(con)
            end
          end
          $PokemonGlobal.phone.contacts = new_contacts
          $PokemonGlobal.phone.sort_contacts
          @scene.pbRefreshList
        end
      end
    end
    @scene.pbEndScene
  end
end
