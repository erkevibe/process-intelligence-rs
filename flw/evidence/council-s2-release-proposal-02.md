# S2-R2: резолюция поставки №2, выбранные сценарии 0.2.0

Новое точное предложение пяти мест СОВЕТа: Root, PM, независимый QA/ProcessLogAuditor, TechnicalDebt/SkillManager, Customer. Большинство три при отсутствии обязательного STOP. Голоса за план S2-P1 и прежнюю S2-R1 не переносятся. S2-R1 заменена после обнаружения cold native PS5 ошибки; её текст и фактические прежние позиции остаются историческими.

## Поставка и неизменный объём

- Frozen runtime source: `d0784e2766f5af875225e62f85aa11f85ccce5d9`, версия `0.2.0`, Windows x86_64, PostgreSQL `18.6`, loopback.
- EXE SHA256: `E2189EA8C463E7E3E146EF7983608A95F474B2FFA35FA02555F8A0CF3E47986E`.
- ZIP SHA256: `E075D999D03729CFC453CCE67BC1400F9413AD7111B750FE873F998D5B47A739`.
- Исходный S2-P1 неизменен: SHA256 `2FA33BCCDDED13CB74C015F3FEA59D1EE0CA05A1B450C748051B321DCF81D7BB`. Все A01–A12 обязательны; неудачи не переименованы в необязательный объём.

Независимый [QA exact11](sprint-02-qa-d0784e.md) подтверждает A01–A12 PASS в выбранном локальном объёме. Новый runtime проверен заново: 49 обычных тестов, отдельно реальные PostgreSQL2 (обычный запуск честно помечает их ignored), jobs6, browser20/roles5, CSV/model/log-cap/ID-collision/lease-loss negatives, actual restart и два одноимённых журнала с сохранением полных exports/hashes. Root fmt/clippy exact frozen прошли. QA и Root независимо проверили 150 frozen-файлов; EXE соответствует proof. Пять независимых Root provenance negatives отклоняют подмены/грязные inputs до создания output; TD не принимает самостоятельно два authored build/package скрипта.

Независимый QA проверил 1635 файлов ZIP по hash/size и protected private DACL текущего пользователя без admin token. Новый пакет реально инициализирован с нуля через native Windows PowerShell5, включая холодный pg_ctl, role/database, ROLLBACK и nonsuperuser. Отдельно PS5 recovery существующей роли при отсутствующей пустой test DB. Прочитаны реальные stdout/stderr. Public Start в стандартном WindowsPS5 child module environment, per-process ExecutionPolicy Bypass, без глобальных изменений: package-CWD browser before20/roles5/UI3, root-owned restart37824→820 и independent after4 PASS. Оба live EXE hashes проверены QA.

Отдельная пользовательская установка тем же ZIP прошла полный cold public nativePS5 Start с нуля на PostgreSQL5435/app3010: health0.2.0 и форма первого аккаунта. QA accounts в ней не создавались. [Root safe proof](sprint-02-root-proof11.json) отдельно фиксирует механизм и identity. R1 с возможными несохранёнными данными остаётся работающим.

## Исправления, история и ограничения

Прежние failed/partial кандидаты не приняты задним числом. Сохранены restore timestamp-order gap, NOTICE/caller CWD, свежий Set-Acl privilege failure, занятый тестовый порт, PS5 UTF8 em-dash parser failure. Затем полный cold native PS5 выявил null ExitCode у exited Start-Process PassThru. Отдельный реальный exit7 control доказал Handle-first механизм; финальный source удерживает Handle перед прежними timeout/nonzero checks, не ослабляя отказ. Новый exact11 cold package и отдельная cold user installation закрыли COLD01 STOP.

Inherited Codex PS7 module path исправлен только в дочернем verifier до стандартного PS5; произвольное загрязнённое cross-shell окружение не сертифицировано. Ошибки приватных verifier (redirect/status, sequence name, port collision, ожидание дерева процессов) отражены отдельно. Два ранних native stderr файла были перезаписаны: доступные diagnostic tool outputs сохранены, полного исторического raw-log покрытия нет. QA заявляет bounded stopped snapshots, не все процессы/CI/lifetime.

Debt остаётся: DB deadlines, измеренный RSS/пределы worst-case work, initdb→private config interruption, небольшие UX замечания Apply→Save и UTF8-byte password limit. Полные исходные R2–R5, legacy oracle/Apromore parity, произвольная BPMN семантика, Split Miner quality, DST/IANA, folders, SSO/TLS/network deployment, distributed jobs и enterprise readiness не объявляются завершёнными.

## Предлагаемое решение

Принять выбранные A01–A12 S2-P1 и публиковать точный ZIP0.2.0 через публичный PR/release. Финальный commit допускает только отчёты/документацию/evidence и один не-runtime CI smoke adjustment: явный `PI_EPHEMERAL=1` для прежнего Linux health smoke, поскольку обычный запуск теперь требует PostgreSQL. CI fmt/clippy/обычные тесты не ослаблены; реальные PG2 подтверждены отдельно локальным QA, CI PG parity не заявляется. Новый фактический CI результат записывается после push; не выдумывается заранее.

Runtime/source/assets/tools/fixtures/tests после exact11 не изменяются; иначе нужна новая проверка/резолюция. Source commit ZIP и merge/tag commit с отчётами/CI указываются раздельно. Начало бюджета06:40:06 UTC, максимум14:40:06 UTC, все отказы/проверки/публикация включены. Actual finish записывается после публикации и проверки установленного приложения.
