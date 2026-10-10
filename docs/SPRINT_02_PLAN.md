# Sprint 02: выбранные сценарии R2–R5 за восемь часов

Начало бюджета: 2026-10-10 06:40:06 UTC / 11:40:06 Asia/Qyzylorda. Конец: 14:40:06 UTC / 19:40:06. Подготовка, установки и проверки входят в 480 минут. Последние 90 минут защищены для независимой проверки и поставки; новые функции после 13:10:06 UTC не начинаются.

Предложение S2-P1, после независимых позиций пяти мест СОВЕТа. Состав: Root; PM /root/pm_final; QA/ProcessLogAuditor /root/qa_process; TechnicalDebt/SkillManager /root/technical_debt; Customer /root/customer. Большинство — три действительных голоса. Независимые QA, TD и STOP не заменяются большинством.

## Защищаемый результат

Одна работающая цепочка: войти → создать проект → импортировать CSV/XES → сохранить и открыть после перезапуска → отфильтровать → построить или загрузить BPMN → изменить и сохранить модель → экспортировать модель/анализ/резервную копию. Второй пользователь и viewer не получают чужие данные или права записи. Фоновая задача после аварийного перезапуска имеет честное конечное состояние.

Это выбранные сквозные сценарии каждого R2–R5. Исходные этапы дорожной карты целиком включают больше функций и проверок. Их полный статус не изменяется на «готово» по одному этому спринту. Legacy oracle, Apromore equivalence, Split Miner, произвольная BPMN семантика, SSO, distributed jobs и enterprise readiness не обещаются. Диагностика недоступного oracle остаётся unverified.

## Обязательная приёмка

Все S2-A01–12 из независимого `flw/evidence/sprint-02-pm-plan.md` обязательны для выбранного объёма; эти ID и критерии включены в точное предложение S2-P1. Реальный PostgreSQL добавлен к A03/A05 как обязательный backend. SQLite или файловая имитация не засчитываются за PostgreSQL. Условный порядок разработки поздних задач не делает их критерии необязательными. Если хотя бы один не выполнен, результат публикуется как частичный с поштучными passed/failed/unverified, без переименования объёма.

1. A01: CSV mapping и preview, корректный quoted delimiter/Unicode, ошибка с номером строки, равенство эквивалентному XES, сохранение предыдущего результата при отказе.
2. A02: явный source/timestamp order, стабильный tie-break, timestamp-order требует timestamp каждого события; lifecycle each-event; политика и исходный SHA256 в export.
3. A03: PostgreSQL transaction, постоянные IDs, два одноимённых журнала, результаты/параметры после настоящего restart; ошибка до commit не заменяет прежние данные.
4. A04: versioned project backup с хешами и restore в отдельный проект; повреждённый/несовместимый bundle отклонён атомарно. Пароли, sessions и чужие проекты не входят в backup.
5. A05: projects и membership owner/editor/viewer; серверная проверка всех log/job/model/export/backup маршрутов известными IDs с двумя отдельными sessions. Нельзя доверять user/role из запроса.
6. A06: локальные setup/login/logout, Argon2id password hashes, серверные ограниченные sessions, HttpOnly/SameSite cookie; session invalidation, cross-origin rejection, отсутствие секретов в экспорте/логах. Развёртывание только loopback.
7. A07: принятые/конечные jobs сохраняются; один атомарный commit результата и completed; отмена и публикация согласованы; restart переводит queued/running в failed/interrupted, без повторной публикации и вечного running.
8. A08: строгий BPMN subset import/view/edit/save/export; смысловые IDs/labels/flows/positions сохраняются. Неподдерживаемая семантика явно отклоняется.
9. A09: именованный baseline observed-variants choice miner сохраняет и экспортирует BPMN; проверяются допустимые наблюдённые последовательности маленького корпуса, без обещания обобщения/fitness/precision Apromore.
10. A10: фильтр трасс по содержащему действию/длине и retain/remove activities; AND-условия трассы применяются к исходным событиям, затем event projection, empty traces сохраняются; counts/variants/DFG пересчитаны, источник неизменен, параметры в export.
11. A11: рабочий календарь fixed UTC offset, выбранные weekdays и часы, даты holidays, полуоткрытые интервалы [start,end), duration по min/max timestamp трассы; независимые границы/выходные. IANA zones/DST и сложные календари явно вне subset.
12. A12: чистый запуск точного SHA, R1 regressions, реальный browser CSV→project→filter→model→export, отрицательные доступ/restore и restart, безопасные evidence и воспроизводимая поставка.

## Контракты и владельцы

Root: Cargo, storage/auth/platform, CSV/normalization, filters/calendar, web.rs/main.rs/jobs.rs, интеграция и scripts. PM: отдельные src/bpmn.rs, static/platform.js/css, templates/platform*.html и пользовательские UI contracts; никакой правки root файлов без поручения. QA: fixtures/tests и независимые evidence, не production. TD: независимый аудит/сопутствующий SkillManager. Customer: ценность/UX и собственные evidence.

BPMN API domain: ProcessModel {name,nodes,flows}; node {id,kind,label,x,y}, kind start/end/task/exclusive_gateway/parallel_gateway; flow {id,source,target,waypoints}. Limits: 1 MiB XML, 1000 nodes, 4000 flows, label4096 UTF-8 bytes. Поддерживается один неисполняемый process; start/end generic, generic task, gateways и sequenceFlow, DI positions/waypoints. DTD, executable process, service/user subprocess, events с definitions, conditions, extensions/collaboration и неизвестные semantic элементы/атрибуты отклоняются. XML с неверным namespace не становится BPMN по одному local name.

Baseline discovery: отдельные пути для каждого наблюдённого варианта, XOR choice, start/end; включает пустой вариант. Это воспроизведение наблюдённых последовательностей без причинностных утверждений. Лимит модели вызывает понятную ошибку, не тихую обрезку.

CSV: UTF-8 header, separator comma/semicolon/tab, точные имена колонок case/activity и optional timestamp/lifecycle; первые пять строк preview; RFC3339 с offset; case/activity пробелы сохраняются, пустые значения отклоняются. source order — строка входа внутри case; timestamp order — сортировка по timestamp, затем исходному ordinal. Case grouping — первое появление case; event ordinal остаётся исходным. Общие admission limits R1 применимы.

Storage/authorization: scoped project repository и отдельные actor view/current; ресурс определяется сервером и проверенным membership. Project IDs и log/model/job IDs устойчивы и не конфликтуют после restart. Durable publication и terminal job snapshot — одна транзакция. Session tokens не публикуются; project backup не восстанавливает sessions/passwords. Database credentials и pgdata приватны в .local. PostgreSQL слушает только loopback, app role не superuser.

## Время, риск и проверки

0:00–0:30: точный СОВЕТ, защита, контракты; 0:30–2:00: PostgreSQL/CSV/persistence; 2:00–3:00: sessions/projects/authorization/jobs recovery; 3:00–4:30: BPMN; 4:30–5:30: filters/calendar; 5:30–6:30: интеграция; 6:30–8:00: независимые исправления, frozen candidate, clean replay, поставка.

Фактические задачи могут идти параллельно; бюджет календарный. PostgreSQL bootstrap probe ограничен 15 минутами, Docker/Java не становятся бесконечным prerequisite. Если среда не готова, сохраняется явный partial verdict и продолжается безопасная независимая работа.

Риск-аппетит: средний для портфеля; низкий для долговечности/backup/доступа, высокий для ограниченного экспериментального discovery. Черновики — облегчённый цикл, интегрированный кандидат — независимые QA/TD/ProcessLogAuditor и реальный СОВЕТ. Подтверждённая потеря данных, обход доступа или ложный durable success требуют STOP затронутой области. Остаточный долг фиксируется с владельцем и проверяемым условием закрытия.
