# 골든타임 ERP (D:TEN)

골든타임365 운영관리시스템. 정적 단일 페이지(`index.html`) + Supabase.

- 배포: Cloudflare Pages가 `main` 브랜치를 그대로 배포합니다 (빌드 명령 없음, 출력 폴더 `/`).
- 데이터·로그인·권한: Supabase (행 단위 보안 정책으로 등급·지점별 접근 제한).
- `sw.js`, `manifest.webmanifest`, 아이콘: 휴대폰 홈 화면 설치(PWA)용.

## sql/
Supabase에 적용한 데이터베이스 변경 기록(순서대로). 이관용 함수(import_*)는 사용 후 삭제했습니다.
