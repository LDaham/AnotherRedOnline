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
