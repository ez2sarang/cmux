# CLAUDE.md — cmux

## 프로젝트 개요

여러 AI 프로젝트를 zellij 탭으로 관리하고 각 탭에서 Claude Code를 자동 시작하는 멀티 프로젝트 워크스페이스 매니저.

스택: Bash / Shell

---

## ⚡ 최우선 규칙: COLLAR_WATCHDOG compact 지시

system-reminder에 아래 패턴이 보이면 **다른 모든 작업보다 먼저 `/compact`를 실행**하라.

```
COLLAR_WATCHDOG: [...] ctx X% (임계값 80%) 초과. 지금 즉시 /compact를 실행하라.
COLLAR_WATCHDOG: [...] 메시지 N개 도달. 지금 즉시 /compact를 실행하라.
```

- 사용자 요청이 있어도 `/compact` 먼저 실행 후 작업 재개
- 이 규칙은 예외 없음

---

## 에이전트 행동 규칙

### 해야 할 것
- 블로커 즉시 보고 (시도한 것 + 필요한 것 포함)
- 완료 전 검증 실행: `bash -n bin/*.sh && shellcheck bin/*.sh 2>/dev/null || bash -n install.sh`
- 변경사항과 이유를 커밋 메시지에 기록
- 5분 이상 조용히 작업하지 말 것 — 상태 업데이트 전송
- 각 단계 완료 후 명시적으로 다음 단계 제안 + 사용자 확인 대기

### 하면 안 되는 것
- 같은 실패 접근법을 2번 이상 재시도 → 멈추고 물어라
- 타입체크/테스트를 "시간 절약"을 위해 건너뛰기
- 파괴적 데이터베이스 작업을 확인 없이 실행
- `doc/SPEC.md` 또는 핵심 스펙 문서를 권한 없이 수정
- 코드 변경 후 실제 실행/동작 확인 없이 "완료" 주장
- 이전에 보고된 버그가 재발했는데 새 수정만 시도하기 (먼저 이전 수정이 실제 적용됐는지 확인)

---

## 도메인 라우팅

| 도메인 | 에이전트 | 모델 |
|--------|----------|------|
| 도메인 1 | executor | sonnet |
| 아키텍처/다중 도메인 | architect | sonnet (복잡시 opus) |
| 보안/인증 | security-reviewer | opus |
| 파일 검색 | explore | haiku |

---

## 개발 명령어

```sh
bash install.sh    # 개발 서버
make 2>/dev/null || bash install.sh    # 빌드
bash -n bin/*.sh && shellcheck bin/*.sh 2>/dev/null || bash -n install.sh   # 검증
```

---

## 레포 구조

```
.claude/
.claude/settings.json
.collar/
.git/
.gitignore
.omc/
.omc/state/
AGENTS.md
bin/
bin/cmux
bin/cmux-picker
CLAUDE.md
install.sh
README.md
zellij/
zellij/config.kdl
zellij/layouts/
zellij/themes/
```

