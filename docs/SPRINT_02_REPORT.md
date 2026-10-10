# Спринт 02: выбранные R2–R5, версия 0.2.0

Все 12 обязательных критериев выбранного объёма прошли независимую проверку. СОВЕТ FLW принял точную резолюцию S2-R2 пятью новыми голосами из пяти. Старые попытки/голоса не заменяют финальную проверку. Публичная доставка и CI на момент исходной записи выполняются; окончательный результат будет добавлен после фактической проверки.

## Что получилось

Рабочая цепочка: создать локальный аккаунт → проект → импорт CSV/XES → фильтры и рабочий календарь → BPMN → изменить подписи/координаты → сохранить и экспортировать → сделать backup и восстановить в отдельный проект. Данные, параметры и модель доступны после настоящего перезапуска. Второй пользователь и viewer проверены по известным чужим IDs; сервер отклоняет запрещённые операции. Принятые jobs сохраняются; interrupted/cancelled не публикуют лишний результат.

| ID | Проверенный результат | Статус выбранного объёма |
|---|---|---|
| A01 | CSV preview/mapping, quoted Unicode, строка ошибки, эквивалентный XES, прежний результат сохранён при отказе | PASS |
| A02 | Source/timestamp order, стабильный tie-break, every-event timestamp requirement, each-event lifecycle, SHA/policy export; restore проверяет порядок | PASS |
| A03 | Реальный PostgreSQL, CAS/atomic batch/rollback, IDs, параметры и два одноимённых журнала после restart | PASS |
| A04 | Версия/hash backup, restore в новый проект; malformed/unsupported/corrupt rejected до commit, auth не экспортируется | PASS |
| A05 | Owner/editor/viewer, отдельные sessions, все scoped resource kinds и view isolation проверены | PASS |
| A06 | Local setup/login/logout, Argon2id, bounded server sessions, HttpOnly/Strict cookie, origin/loopback protection | PASS |
| A07 | Durable accepted/terminal jobs, cancel/publication agreement, interrupted recovery и result+completed atomicity | PASS |
| A08 | Strict BPMN subset, canvas node label/position Apply/Save/XML round trip; unsupported и oversized models rejected | PASS |
| A09 | Именованный observed-variants choice baseline, проверенный маленький язык трасс/empty path | PASS |
| A10 | AND predicates на исходных трассах, retain/remove projection, empty traces и counts/params/source integrity | PASS |
| A11 | Fixed UTC offset/weekdays/hours/holidays, half-open min/max intervals и независимые границы; понятное представление времени | PASS |
| A12 | Exact build/clean package/native PS5 cold install, real browser, отрицательные доступ/restore и actual restart | PASS |

## Точная проверка и поставка

Frozen application source: `d0784e2766f5af875225e62f85aa11f85ccce5d9`. EXE SHA256: `E2189EA8C463E7E3E146EF7983608A95F474B2FFA35FA02555F8A0CF3E47986E`. Windows ZIP SHA256: `E075D999D03729CFC453CCE67BC1400F9413AD7111B750FE873F998D5B47A739`. Source commit ZIP отличается от последующего merge/tag commit с отчётами/CI; runtime после приёмки не меняется.

Свежая release-сборка и 49 обычных тестов прошли; fmt/clippy exact frozen прошли. Два PostgreSQL-теста в обычном запуске явно ignored и отдельно реально исполнены независимым QA на изолированной БД. QA заново проверил exact11 jobs6, browser20, roles5, CSV/model/log-cap/ID-collision/lease-loss negatives и restart с полными exports двух одноимённых журналов. Exact package: 1635 hash/size совпали, private DACL без admin token, fresh native PS5 bundled PostgreSQL cold initialization, nonsuperuser/ROLLBACK и recovery отсутствующей test DB. Package-CWD browser20/roles5/UI3 и actual37824→820 restart/after4 прошли.

Отдельная пользовательская установка тем же ZIP прошла полный native public Start с пустой БД на HTTP3010/PostgreSQL5435; открывается форма первого аккаунта, тестовые аккаунты в неё не добавлены. R1/HTTP3000 с возможными несохранёнными результатами не остановлен. Настройки запуска/данные остаются в защищённом локальном каталоге; passwords не опубликованы.

Главные доказательства: [QA](../flw/evidence/sprint-02-qa-d0784e.md), [package proof](../flw/evidence/sprint-02-qa-package11.json), [Root safe proof](../flw/evidence/sprint-02-root-proof11.json), [Council](../flw/evidence/council-s2-release.md), [TD](../flw/evidence/sprint-02-debt.md). Полные приватные credentials/пользовательская переписка/сырой DB не публикуются.

## Реальные отказы и исправления

Независимый аудит нашёл restore timestamp-order gap; restore теперь повторно нормализует source по заявленной policy и отклоняет missing/descending timestamps до commit. Затем точная упаковка выявила missing NOTICE и caller CWD; provenance scripts исправлены и пять отрицательных проверок реально отклонили modified EXE/frozen source, dirty inputs, wrong commit/version до output.

Чистая установка выявила Set-Acl SeSecurityPrivilege; DACL-only применение с PS5/7 postcondition проверено без admin. Занятые private test ports диагностированы, выбран свободный порт без остановки чужих процессов. Native PS5 выявил non-ASCII/no-BOM parser issue — сообщение сделано ASCII. Inherited Codex PS7 module contamination исправлено только в child verifier до stock PS5; arbitrary custom module environment не сертифицировано.

Наконец полный cold native PS5 запуск выявил null ExitCode у exited Start-Process. Реальный exit7 control подтвердил Handle-first; exact11 удерживает Handle перед прежним timeout/nonzero gate. Новый холодный запуск и public user installation прошли. Старый S2-R1 superseded; ранее полученные PM/TD голоса исторические, новые пять голосов относятся только к S2-R2.

Ошибки приватных verifier (CLI sequence/redirect/status, selector/JSON reserialization, oversize copy/port/descendant wait) не скрыты и не объявлены продуктовым PASS. Два ранних native stderr файла перезаписаны: diagnostic tool outputs сохранены, полного historical raw coverage нет. QA покрывает конкретные остановленные snapshots, не всю жизнь процессов и не невыполненный CI.

## Что осталось

Это выбранная сквозная первая реализация R2–R5; исходные этапы [roadmap](ROADMAP.md) целиком не завершены. Не подтверждены legacy oracle/Apromore equivalence, качество Split Miner, произвольный BPMN, DST/IANA, папки/жизненный цикл проектов, migrations/audit, SSO/TLS/network deployment и distributed jobs. Следующий спринт: oracle/corpus и эксплуатационные гарантии PostgreSQL, затем расширение проектов/BPMN по приоритетным сценариям.

Открытый долг: явные DB deadlines, измеренный RSS/worst-case workload, recovery между initdb и private config, небольшие UX замечания Apply→Save и UTF8 bytes для пароля. Локальный объём не означает enterprise readiness.

Бюджет: начало `2026-10-10 06:40:06 UTC` / `11:40:06 Asia/Qyzylorda`; предел `14:40:06 UTC` / `19:40:06`, восемь часов. Подготовка, ошибки, повторные проверки и публикация входят в лимит. Приёмка продукта получена до предела; actual remote verification time и CI result добавляются после выполнения. Linux CI health smoke явно использует поддержанный ephemeral mode; реальные PG2 — отдельное локальное QA evidence, CI PG parity не заявляется.
