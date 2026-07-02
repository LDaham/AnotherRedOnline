#===============================================================================
# Another Red Online — per-turn choice serialization (Phase 4)
#
# A battler's committed action lives in `Battle#choices[idxBattler]`:
#   [:UseMove,   idxMove, moveObject, idxTarget]
#   [:SwitchOut, idxParty, nil, -1]
#   [:Shift,     0, nil, -1]
#   [:Run,       0, nil, -1]
#   [:None,      0, nil, -1]
#
# We send only the small primitives over the wire (idxMove/target/party) plus the
# ABSOLUTE canonical battler index. Because both peers share the same battler
# layout (side0=host, side1=guest), the receiver applies a choice to the exact
# same index the sender used — no mirroring/translation needed. The moveObject is
# rebuilt locally from `battler.moves[idxMove]`, never trusted off the wire.
#===============================================================================
module ARNet
  module Choices
    module_function

    # Battle#choices entry -> compact Hash. `idx` is the absolute battler index.
    def choice_to_h(choice, _battler, idx)
      h = { "idx" => idx }
      case choice[0]
      when :UseMove
        h["a"] = "move"; h["mv"] = choice[1]; h["tg"] = choice[3]
      when :SwitchOut
        h["a"] = "switch"; h["pt"] = choice[1]
      when :Shift
        h["a"] = "shift"
      when :Run
        h["a"] = "run"
      else
        h["a"] = "none"
      end
      h
    end

    # Apply a received choice Hash to battle.choices[idx]. Sets the entry directly
    # (mirrors exactly what the sender registered) so receiver-side re-validation
    # can't diverge from the sender. Returns true on success.
    def apply_choice(battle, idx, h)
      ch = (battle.choices[idx] ||= [:None, 0, nil, -1])
      case h["a"]
      when "move"
        mi = h["mv"].to_i
        battler = battle.battlers[idx]
        mv = battler && battler.moves[mi]
        return false unless mv && mv.id
        ch[0] = :UseMove; ch[1] = mi; ch[2] = mv; ch[3] = (h["tg"] || -1).to_i
      when "switch"
        ch[0] = :SwitchOut; ch[1] = h["pt"].to_i; ch[2] = nil; ch[3] = -1
      when "shift"
        ch[0] = :Shift; ch[1] = 0; ch[2] = nil; ch[3] = -1
      when "run"
        ch[0] = :Run; ch[1] = 0; ch[2] = nil; ch[3] = -1
      else
        ch[0] = :None; ch[1] = 0; ch[2] = nil; ch[3] = -1
      end
      true
    end
  end
end
