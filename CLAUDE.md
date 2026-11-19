# CLAUDE.md — cmux

## 프로젝트 개요

여러 AI 프로젝트를 zellij 탭으로 관리하고 각 탭에서 Claude Code를 자동 시작하는 멀티 프로젝트 워크스페이스 매니저.

스택: Bash / Shell

## 실행 환경

- macOS: Ghostty → zsh → cmux/zellij → macOS 에이전트 CLI.
- Windows: **Noctty → WSL(Ubuntu) → zsh → cmux/zellij → Windows 네이티브 Codex**. PowerShell에서 cmux가 직접 실행되는 환경으로 가정하지 않는다.
- WSL의 Codex 진입점은 `bin/cmux-codex-windows`다. npm 내부 `codex.exe`를 직접 호출하면 설치 방식 정보가 빠져 업데이트 승인창이 생략될 수 있으므로 Windows `node.exe`로 공식 `codex.js`를 실행한다.
- OS 분기·설치·업데이트 확인 절차는 `README.md`의 실행 환경 절을 따른다. macOS 실기기 검증과 Windows/WSL 검증 결과를 구분한다.

---


## 복잡한 작업 오케스트레이션 — collar-conductor 필수

**3단계 이상 멀티스텝 작업**은 직접 Agent() 호출 금지. `collar-conductor`를 통해 Executor→Verifier 루프로 실행:

```bash
collar-conductor run "태스크 설명" --rounds 3
collar-conductor run "태스크 설명" --rounds 5 --model complex
collar-conductor log    # 이력 확인
```

collar-conductor가 자동으로:
1. **Executor 에이전트** → 실제 코드 구현 (Sonnet)
2. **Verifier 에이전트** → 독립 검증 (Sonnet)
3. `NEEDS_WORK` 시 재작업 지시 (최대 --rounds 횟수)
4. `APPROVED` 시 완료 선언 + 로그 기록

| 작업 유형 | 방법 |
|---------|------|
| 단일 파일 수정 | 직접 Edit/Write |
| 2단계 이하 | Agent() + 체크리스트 파일 |
| 3단계+ / 복잡한 구현 | `collar-conductor run` 필수 |

**절대 금지:** 체크리스트 파일 없이 Agent() 호출 (훅 40-task-guard.sh가 감지·경고)

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

<!-- collar:claude:begin v1 -->
## collar 공통 규칙 (자동 관리 블록)
- 전역 규칙은 `~/.claude/CLAUDE.md` 자동 로드, 상세는 `~/.collar/ref/`.
- 운영 사실(포트·DB·스택·명령어)은 `.collar/project-facts.md` 우선.
- 완료 보고는 STARTED(코드만)·TESTED(로컬 통과)·VERIFIED(실환경) 단계와 증거를 밝힌다.
<!-- collar:claude:end -->
