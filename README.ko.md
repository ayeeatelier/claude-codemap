# claude-codemap

[![ci](https://github.com/ayeeatelier/claude-codemap/actions/workflows/ci.yml/badge.svg)](https://github.com/ayeeatelier/claude-codemap/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[English](README.md) · **한국어** · [日本語](README.ja.md)

claude-codemap은 소스 파일의 역할·주요 심볼·의존성·주의사항을 마크다운으로 저장하는 Claude Code 플러그인입니다. 이후 세션에서는 코드베이스를 검색하기 전에 이 기록을 참고하도록 Claude에게 안내합니다.

Claude가 소스를 읽고 파일마다 요약을 작성하며, 결과는 모듈별로 묶어 `docs/codemap/`에 저장합니다. 아래는 파일 하나에 대한 요약 예시입니다.

```markdown
### src/payments/webhook.ts — Stripe 웹훅 수신부
- Symbols: handleWebhook, verifySignature, replayGuard
- Depends on: stripe, PaymentStore, AuditLog
- Gotchas: 요청 본문을 JSON으로 파싱하기 전에
  원본 본문으로 서명을 검증해야 함.
```

요약은 프로젝트 안에 마크다운 파일로 남습니다. 별도의 데몬이나 빌드 단계는 필요하지 않습니다.

## 사용방법

### 1. 준비 및 설치

플러그인을 지원하는 Claude Code 터미널 CLI를 사용합니다. 훅을 실행하려면 **bash, Git, jq**가 PATH에 있어야 합니다. macOS와 Linux에서 확인했으며, Windows는 미검증입니다.

jq가 없다면 터미널에서 설치합니다. macOS는 `brew install jq`, Debian/Ubuntu는 `sudo apt-get install jq`를 실행합니다. jq가 없으면 코드맵 사용 안내·변경 추적·갱신 알림이 동작하지 않으며, 코드맵이 있는 프로젝트에서는 훅이 의존성 누락을 알립니다.

Claude Code에서 이 저장소를 플러그인을 받아올 곳으로 등록합니다.

```text
/plugin marketplace add ayeeatelier/claude-codemap
```

등록한 곳에서 codemap을 설치합니다.

```text
/plugin install codemap@claude-codemap
```

설치 범위를 묻는다면 여러 프로젝트에서 혼자 사용할 때는 **User**, 이 프로젝트의 협업자와 설정을 공유할 때는 **Project**, 이 프로젝트에서 혼자 사용할 때는 **Local**을 선택합니다. 범위와 활성화에 관한 자세한 내용은 [Claude Code 설치 안내](https://code.claude.com/docs/en/discover-plugins#install-plugins)를 참고하세요.

### 2. 프로젝트 코드맵 생성

설치 후, 코드맵을 만들 프로젝트에서 새 Claude Code 세션을 시작하고 요청합니다.

> 이 프로젝트 코드맵 만들어 주세요.

`/codemap:codemap-init`으로 스킬을 직접 실행할 수도 있습니다.

Claude가 소스 파일 목록을 확인하고, 스캐너 에이전트를 병렬로 실행해 소스를 읽은 뒤 인덱스를 작성합니다. 스킬에는 완료를 알리기 전에 요약에 포함된 경로와 소스 파일 목록을 대조하도록 지시가 들어 있습니다.

생성 후 `docs/codemap/README.md`에서 모듈 목록과 갱신 규칙을 확인하세요. 각 모듈의 마크다운 파일에는 파일별 요약이 들어 있습니다. 이후 세션에는 이 인덱스를 참고하라는 안내가 추가됩니다. `docs/codemap/`이 없는 프로젝트에는 훅이 아무 작업도 하지 않습니다.

<details>
<summary>다른 설치 방법: 로컬 클론 사용</summary>

터미널에서 저장소를 클론합니다.

```sh
git clone https://github.com/ayeeatelier/claude-codemap.git
```

Claude Code에서 위의 GitHub 등록 명령 대신 클론한 디렉터리를 등록합니다. 예시 경로를 실제 절대 경로로 바꾸세요.

```text
/plugin marketplace add /absolute/path/to/claude-codemap
```

그다음 `/plugin install codemap@claude-codemap`을 실행하고, 위의 2단계에 따라 프로젝트 코드맵을 생성합니다. 플러그인을 클론하거나 설치하는 것만으로 프로젝트의 인덱스가 만들어지지는 않습니다.

</details>

## 동작 방식과 갱신

플러그인은 훅 3개, `codemap-init` 스킬, Haiku 스캐너 에이전트로 구성됩니다. 훅은 경로를 기록하고 Claude에게 지시를 전달하며, 요약을 작성하는 것은 Claude입니다.

| 시점 | 플러그인이 하는 일 |
| --- | --- |
| 세션 시작·재개·컨텍스트 압축 후 | 광범위한 코드 검색 전에 인덱스를 읽으라는 안내를 추가합니다. |
| Claude가 Edit 또는 Write로 소스 수정 | 나중에 요약을 갱신할 수 있도록 경로를 `docs/codemap/.stale`에 기록합니다. |
| Claude가 Bash로 실행한 명령에서 `git commit`을 감지 | 갱신 대기 항목이 있으면 기능 완료를 알리기 전에 요약을 갱신하도록 요청합니다. 명령 실행 후의 알림이며, Git 커밋을 차단하지 않습니다. |

**변경 추적은 Claude의 도구 사용에 한정됩니다.** 외부 편집기, 셸 스크립트, `git pull`로 인한 변경이나 파일 삭제·이동은 자동으로 기록되지 않습니다. 일반 터미널의 커밋도 알림을 발생시키지 않습니다. 실패한 커밋이나 중간 커밋에도 알림이 나올 수 있으며, 이때는 무시하도록 Claude에게 안내합니다.

작업을 마무리하기 전이나 요약이 오래되었을 때 Claude에게 요청하세요.

> 플러그인의 큐 도구로 갱신 대기 중인 코드맵 항목을 갱신하고, 현재 소스와 맞는지 확인해 주세요.

세션 안내에는 Claude가 큐에서 처리할 경로를 가져오고, 요약을 갱신한 뒤 완료 처리하는 방법이 포함됩니다. 갱신 중 발생한 변경이 남아 있어야 하므로 `.stale` 등 큐 파일을 직접 비우지 마세요. 중단된 갱신도 같은 큐 도구로 다시 처리할 수 있습니다.

Claude 밖에서 수정했다면 삭제·이동한 파일을 포함해 변경한 경로를 알려주고, 해당 요약과 모듈 목록을 갱신하도록 요청하세요. 어떤 파일이 바뀌었는지 모른다면 프로젝트 코드맵을 다시 만들어 달라고 요청합니다.

<details>
<summary>그림으로 보기: 소스 검색과 코드맵을 참고한 탐색</summary>

![왼쪽은 소스 검색으로 파일을 찾고, 오른쪽은 저장된 코드맵 요약을 참고한 뒤 소스를 확인하는 비교 예시입니다.](docs/assets/codemap-concept-v2.png)

왼쪽은 소스 검색으로 관련 파일을 찾는 예시이고, 오른쪽은 파일별 역할·주요 심볼·의존성·주의점이 담긴 요약을 참고해 확인할 소스를 좁히는 예시입니다. 어느 쪽이든 실제 소스 확인은 필요합니다. 탐색 흐름을 설명하는 그림이며, 성능 측정 결과는 아닙니다.

요약은 Claude가 작성해 `docs/codemap/`에 Markdown으로 저장합니다. 훅은 Edit·Write로 바뀐 경로를 기록하고 갱신을 알립니다. 갱신할 때 Claude는 claim으로 대기 중인 경로를 가져와 해당 요약을 수정한 뒤, complete로 그 배치를 완료 처리합니다. 훅이 요약을 직접 다시 쓰지는 않습니다. Claude 밖에서 수정한 내용은 별도로 갱신을 요청해야 합니다.

</details>

## 비용과 효과

최초 생성에는 선택한 소스 파일을 읽고 요약을 작성하는 토큰이 필요합니다. 이후에도 세션 안내, 관련 요약 읽기, 변경된 요약의 재작성에 토큰을 사용합니다. 총사용량은 프로젝트와 작업 방식에 따라 달라집니다.

개발 중 수행한 소규모 실험에서는 질문 2개를 대상으로 인덱스 유무를 총 3회 비교했고, 인덱스가 있을 때 토큰이 25~39% 적게 사용되었습니다. 다만 이 저장소에는 같은 실험을 재현하거나 금전적 절감액·손익분기점을 계산하기에 충분한 자료가 없습니다. 기록된 수치와 한계는 [측정 메모](docs/measurement-notes.md)(영문)를 참고하세요.

## 알아두면 좋은 것

- 요약에는 오류나 누락이 있을 수 있습니다. 코드의 위치와 역할을 파악하는 데 활용하되, 판단에 필요한 내용은 소스에서 확인하세요. 인덱스와 소스가 다르면 인덱스를 고칩니다.
- LSP는 선택사항이며 별도로 설치합니다. 사용 가능할 때 정확한 정의 위치·참조·호출 계층을 찾는 데 우선 사용하도록 안내합니다. [LSP 설정 안내](docs/lsp-setup.md)(영문)를 참고하세요. codemap 자체는 호출 그래프를 만들지 않습니다.
- 주요 소스 확장자는 기본 지원합니다. 다른 확장자는 `docs/codemap/.extensions`에 점 없이 한 줄에 하나씩 추가하세요. 벤더 디렉터리, 빌드 결과물, 코드맵 디렉터리 자체는 추적에서 제외됩니다.
- 작은 저장소에서는 요약 유지 비용이 반복 검색 비용보다 클 수 있습니다. 초기화 스킬은 아주 작은 프로젝트에서는 먼저 경고하고, 큰 프로젝트에서는 단계별 생성을 제안하도록 되어 있습니다. 이는 실측으로 정한 기준이 아닌 경험칙입니다.

## 기여

버그 리포트와 PR을 환영합니다. 큰 변경은 이슈로 먼저 논의해 주세요. 구현에는 Bash와 awk를 사용하며, 스캐너와 스킬 지시문은 마크다운입니다.

PR을 보내기 전에 저장소 루트에서 다음 검증을 실행하세요.

```sh
bash tests/run.sh
```

```sh
shellcheck scripts/*.sh tests/*.sh
```

CI에서도 두 검증을 실행합니다. 공개 문서를 수정할 때는 README 3개 언어판과 `docs/index.html`의 각 언어 섹션에 같은 내용을 반영해 주세요.

모델을 호출하지 않고 실제 Claude Code 검증 시나리오를 확인하려면 다음 명령을 실행합니다.

```sh
bash tests/live-claude-code.sh --dry-run
```

Claude Code 인증을 마친 뒤 라이브 검증을 실행합니다.

```sh
bash tests/live-claude-code.sh --live
```

라이브 검증은 `--plugin-dir`로 현재 체크아웃을 불러오고, 소스 파일 2개가 있는 일회용 프로젝트에서 코드맵 생성·수정 감지·큐 갱신·커밋 알림을 확인합니다. 모델 토큰을 사용합니다. 실패한 실행은 fixture와 JSONL 로그를 보존하며, 성공한 실행도 남기려면 `--keep`을 사용하세요.

## 라이선스

[MIT](LICENSE)
