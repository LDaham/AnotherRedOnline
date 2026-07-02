#===============================================================================
# Another Red Online — deterministic battle RNG (Phase 4 foundation)
#
# Lockstep determinism requires both peers to draw identical random numbers in
# identical order. Essentials funnels ALL battle-simulation randomness through the
# single method `Battle#pbRandom(x)` (audit: see decompiled/HOOKS.md). We override
# it to draw from a shared, seeded PRNG during online battles; offline battles keep
# the original Kernel#rand behavior untouched.
#
# We use a self-contained SplitMix64 generator rather than Ruby's `Random` so the
# sequence is byte-for-byte reproducible regardless of Ruby/MT implementation
# details — only the 64-bit seed (derived from both peers' nonces) matters.
#===============================================================================
module ARNet
  class PRNG
    MASK64 = 0xFFFFFFFFFFFFFFFF
    POW64  = 1 << 64
    GAMMA  = 0x9E3779B97F4A7C15

    def initialize(seed)
      @state = seed.to_i & MASK64
    end

    # Raw 64-bit output (SplitMix64).
    def next_u64
      @state = (@state + GAMMA) & MASK64
      z = @state
      z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
      z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
      (z ^ (z >> 31)) & MASK64
    end

    # Integer in 0...x (x > 0), matching the pbRandom(x) contract. Unbiased via
    # rejection sampling so no modulo bias creeps in.
    def rand(x)
      x = x.to_i
      return next_u64 if x <= 0   # not used in the battle sim; safety only
      thresh = POW64 - (POW64 % x)
      loop do
        r = next_u64
        return r % x if r < thresh
      end
    end

    # Snapshot/restore of internal state (for per-turn checksums / debugging).
    def state; @state; end
    def state=(v); @state = v.to_i & MASK64; end
  end

  # Attach a deterministic PRNG to a battle from the shared 64-bit seed.
  # Call right after the Battle object is created for an online match.
  def self.attach_prng(battle, seed)
    battle.arnet_prng = ARNet::PRNG.new(seed)
  end
end

class Battle
  # Seeded PRNG for online (lockstep) battles; nil for normal single-player.
  attr_accessor :arnet_prng

  # THE battle-sim RNG chokepoint. Online -> shared seeded PRNG (identical on both
  # peers). Offline -> original behavior.
  def pbRandom(x)
    return @arnet_prng.rand(x) if @arnet_prng
    return rand(x)
  end
end
