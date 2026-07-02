#===============================================================================
# Another Red Online — 온라인 대전 배속 무력화 (Delta Speed Up 우회)
#
# 이 게임은 `26_Delta Speed Up` 플러그인으로 상시 최소 1.3배로 돈다
# (SPEEDUP_STAGES=[1.3, 3], 1.0배 스테이지 자체가 없음). Delta는
#     System.uptime = SPEEDUP_STAGES[$GameSpeed] * System.unscaled_uptime
# 로 오버라이드하고, 배틀 시작 시 $GameSpeed=battle_speed(플레이어별 설정, 0/1)로
# 세팅하며, 배틀 커맨드 페이즈 중 AUX1로 배속을 더 바꿀 수도 있다. 즉 배속은
# "플레이어마다 다르게" 걸려 있다.
#
# 온라인 대전은 (1) 플레이어별 배속 설정에 영향받지 않고 항상 1.0배로 보여야 하고
# (2) 체스클록/선출 카운트다운이 실시간과 같게 흘러야 공정하다. 따라서 온라인
# 플로우 동안($arnet_no_speedup=true) System.uptime이 배속 배율을 무시하고 원본
# 실시간(unscaled_uptime, Delta가 별칭으로 보존해 둔 진짜 uptime)을 반환하도록
# 재오버라이드한다. 우리 플러그인은 로드 순서상 Delta Speed Up(26) 다음(30, 마지막)
# 이므로 이 재오버라이드가 최종 적용된다.
#
# 결정론에는 영향 없음: 시뮬은 시드된 PRNG + 교환 커맨드로만 진행되고 실시간에
# 의존하지 않는다. 배속은 애니메이션 페이싱/타이머 계측용 표시 값일 뿐이다.
# AUX1을 눌러 $GameSpeed가 바뀌어도 배율이 무시되므로 온라인 중엔 무효.
# 프레임레이트(60fps)는 배속과 무관하므로 프레임 카운트 기반 타임아웃(_pump_until)은
# 원래부터 실시간이라 영향 없음 — System.uptime 기반인 [013]/[014]만 바로잡힌다.
#
# $arnet_no_speedup 플래그는 [011] PCMenuHook 이 온라인 플로우 진입 시 set,
# 종료(ensure) 시 clear 한다(예외/조기 이탈에도 항상 복구).
# [[online-rules-and-clock]] [[engine-hook-points]]
#===============================================================================
if defined?(System) && System.respond_to?(:unscaled_uptime)
  module System
    class << self
      alias_method :arnet_prescale_uptime, :uptime unless method_defined?(:arnet_prescale_uptime)
    end

    # 온라인 플로우 중에는 배속 배율을 무시하고 실시간을 돌려준다.
    def self.uptime
      return System.unscaled_uptime if $arnet_no_speedup
      System.arnet_prescale_uptime
    end
  end
end
