#===============================================================================
# Another Red Online — 온라인 대전 배속 고정 (Delta Speed Up 우회)
#
# 이 게임은 `26_Delta Speed Up` 플러그인으로 상시 최소 1.3배로 돈다
# (SPEEDUP_STAGES=[1.3, 3], 1.0배 스테이지 자체가 없음). Delta는
#     System.uptime = SPEEDUP_STAGES[$GameSpeed] * System.unscaled_uptime
# 로 오버라이드하고, 배틀 시작 시 $GameSpeed=battle_speed(플레이어별 설정, 0/1)로
# 세팅하며, 배틀 커맨드 페이즈 중 AUX1로 배속을 더 바꿀 수도 있다. 즉 순정 배속은
# "플레이어마다 다르게" 걸려 있어, 온라인에서 양쪽 화면 페이싱이 어긋날 수 있다.
#
# 그래서 온라인 플로우 동안($arnet_no_speedup=true) System.uptime을 다시 오버라이드
# 하여 플레이어별 설정(및 AUX1 토글)을 무시하고 항상 ARNET_ONLINE_SPEED(=1.3배)의
# 고정 배율만 적용한다. 상수라 양 피어가 완전히 동일한 배속으로 돌아 어긋날 일이
# 없다(원래 1.0배로 고정했었으나, 순정 기본값과 같은 1.3배로 상향). 우리 플러그인은
# 로드 순서상 Delta Speed Up(26) 다음(30, 마지막)이므로 이 재오버라이드가 최종 적용.
#
# 결정론에는 영향 없음: 시뮬은 시드된 PRNG + 교환 커맨드로만 진행되고 실시간에
# 의존하지 않는다. 배속은 애니메이션 페이싱/타이머 계측용 표시 값일 뿐이다.
# 프레임레이트(60fps)는 배속과 무관하므로 프레임 카운트 기반 타임아웃(_pump_until)은
# 원래부터 실시간이라 영향 없음.
#
# 체스클록/선출 카운트다운([013]/[014])은 "생각하는 시간"이라 배속과 무관하게 실제
# 45초/7분/90초를 유지해야 한다. 그래서 그 둘은 System.uptime이 아니라 아래
# ARNet.clock_now(=배속 미적용 원본 uptime)를 쓴다 — 애니만 1.3배, 클록은 실시간.
#
# $arnet_no_speedup 플래그는 [011] PCMenuHook 이 온라인 플로우 진입 시 set,
# 종료(ensure) 시 clear 한다(예외/조기 이탈에도 항상 복구).
# [[online-rules-and-clock]] [[engine-hook-points]]
#===============================================================================
ARNET_ONLINE_SPEED = 1.3 unless defined?(ARNET_ONLINE_SPEED)   # 온라인 고정 배속(양 피어 동일)

# 체스클록/선출 카운트다운 전용 실시간 시계(초). 위 배속 오버라이드와 Delta Speed Up의
# System.uptime 배율을 타지 않는 원본 uptime을 돌려준다 — 배속과 무관하게 45초/7분/90초를
# 실제 초로 유지. Delta의 unscaled_uptime(진짜 uptime 별칭)이 있으면 그걸, 없으면 uptime.
module ARNet
  def self.clock_now
    (System.respond_to?(:unscaled_uptime) ? System.unscaled_uptime : System.uptime)
  end
end

if defined?(System) && System.respond_to?(:unscaled_uptime)
  module System
    class << self
      alias_method :arnet_prescale_uptime, :uptime unless method_defined?(:arnet_prescale_uptime)
    end

    # 온라인 플로우 중에는 플레이어별 배속을 무시하고 고정 배율만 적용한다.
    def self.uptime
      return System.unscaled_uptime * ARNET_ONLINE_SPEED if $arnet_no_speedup
      System.arnet_prescale_uptime
    end
  end
end
