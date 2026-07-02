# Another Red Online — 설치 & 자동 업데이트

온라인 대전 모드를 설치하고, 게임을 켤 때마다 **자동으로 최신 버전을 유지**하는 런처입니다.

## 설치 (사용자)

1. **깨끗한** Another Red 게임 폴더(= `Game.exe`가 있는 폴더)를 준비합니다.
   - 이미 이 모드가 적용된 폴더가 아니어야 합니다. 처음 실행 시 원본
     `Data/PluginScripts.rxdata`를 `.arnet_base`로 백업해 두고, 업데이트할 때마다
     그 원본에서 다시 만들기 때문입니다.
2. 이 폴더의 **`Another Red Online.bat`** 와 **`launcher.ps1`** 두 파일을
   게임 폴더(`Game.exe` 옆)에 복사합니다.
3. 앞으로는 `Game.exe` 대신 **`Another Red Online.bat`** 로 게임을 실행합니다.

끝입니다. 실행할 때마다 GitHub에서 최신 버전을 확인해서, 새 버전이 있으면
플러그인과 에셋을 그 자리에서 갱신한 뒤 게임을 띄웁니다. 인터넷이 안 되거나
업데이트 확인에 실패하면 그냥 현재 설치된 버전으로 실행합니다(오프라인 플레이 OK).

> 바로가기를 만들고 싶으면 `Another Red Online.bat`의 바로가기를 만들어 아이콘만
> 바꿔 두면 됩니다.

## 동작 방식

- `dist/manifest.json`의 `version`을 게임 폴더의 `arnet_version.txt`와 비교합니다.
- 새 버전이면 `dist/element.bin`(플러그인)과 `dist/assets/**`(BGM 등)를 내려받아
  SHA-256으로 검증한 뒤:
  - `PluginScripts.rxdata` = (원본 `.arnet_base`) + (모드 element) 로 다시 씁니다.
    기존 베이스 게임의 다른 플러그인은 건드리지 않습니다(surgical append).
  - 에셋을 게임 폴더에 복사합니다.
- 모드 버전이 서로 다른 두 플레이어는 배틀 로직 차이로 desync가 나므로, 매칭
  핸드셰이크에서 버전이 다르면 대전을 거부하고 안내합니다. 런처가 모두를 최신으로
  유지하므로 실제로는 거의 발생하지 않습니다.

## 릴리스 (개발자)

새 버전을 배포하려면:

1. `plugin/AnotherRedOnline/meta.txt`의 `Version` 과
   `plugin/AnotherRedOnline/[001] NetProtocol.rb`의 `MOD_VERSION` 을 함께 올립니다.
2. 페이로드를 빌드합니다:
   ```
   python tools/build_dist.py
   ```
3. `dist/` 를 커밋 & 푸시합니다. 각 사용자의 런처가 다음 실행 때 자동으로 받습니다.

로컬 개발 게임에 바로 굽고 싶으면 기존 흐름을 그대로 씁니다:
```
python tools/plugin_baker.py restore
python tools/plugin_baker.py bake
```
`build_dist.py`의 append 결과는 `plugin_baker.py bake`와 바이트 단위로 동일함이
검증되어 있습니다.
