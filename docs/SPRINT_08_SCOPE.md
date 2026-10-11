# Sprint08: оставшиеся условия R2–R5 и шестичасовая итерация

Окно 11 октября 2026 года: 03:42–09:42 UTC. Пользователь просит дойти до полного закрытия R2–R5. Это целевой результат программы работ; шестичасовой срок не отменяет исходных условий дорожной карты и независимых доказательств. Ни полный service oracle, ни Split Miner нельзя объявить завершёнными только потому, что появились Rust API или совпали несколько counts.

## Фактическая исходная точка

Принятое приложение0.5 имеет CSV/XES, проекты и RBAC, долговечные jobs, PostgreSQL/schema2/CAS, восстановление, загрузку по запросу и ограниченный кеш. Спринты06–07 добавили независимый узкий parser/XLog oracle и отдельный developer preview. Preview ещё не подключён к операторскому HTTP/UI импорту. Reference07 исполняет побайтово извлечённые validateLog/isInvalidEvent на настоящих OpenXES, а не оригинальный service-класс или весь pipeline.

В auth.rs Project содержит id/name/members; folder/audit/project archive-delete API не обнаружены в просмотренных публичных API/routes. bpmn.rs поддерживает start/end/task/exclusive/parallel и observed_variants_choice_v1, не Split Miner. calendar.rs использует FixedOffset, не IANA/DST; Cargo.toml не содержит chrono-tz. Эти наблюдения относятся к прочитанным текущим файлам, а не ко всем историческим частным журналам.

## Конечная матрица закрытия

Любой пункт получает PASS только на именованном неизменном кандидате с входами/параметрами/выходами, версией окружения, независимой проверкой и публичной поставкой. BLOCKED, FAILED и NOT-IN-RUN показываются рядом. Несколько успешных пунктов не компенсируют другой обязательный провал. Старые принятые доказательства можно переиспользовать при подтверждённой идентичности соответствующего исходника/контракта.

| ID | Остаточное условие полного этапа | Доказательство и зависимость |
|---|---|---|
| R2-01 | Воспроизводимый canonical Core/service oracle | Original unchanged service class и реальные reachable dependencies; фиксированные source/tree/jars/classes/JDK/параметры; настоящий import path, parser fallback/default naming/factory selection и validateLog. Если сервисный путь с auth/persistence входит в выбранный сценарий, его реальные зависимости тоже исполняются. Extracted methods или reachable stubs не закрывают этот пункт. |
| R2-02 | Полный согласованный контракт выбранного импорта | Явная матрица source/time ordering, names/defaults/classifiers, timestamp precision/offset/lifecycle и unsupported attributes; новый frozen corpus и отдельные сравнения. Полные attributes/classifiers нельзя молча заменить узкой EventLog моделью. Поддержанный subset допускается лишь как явно принятый контракт, не как полный service parity. |
| R2-03 | Операторский preview и подтверждение нового результата | Оригинальный файл/hash сохраняется; counts/source identities/defaults/removals/refusals видны до записи; подтверждение создаёт новый результат и durable policy/action record; RBAC, raw limits, session binding, повтор/отмена/restart проверены. Строгий обычный импорт сохраняется. |
| R2-04 | Предыдущие восемь прикладных сценариев | R2-C01–08 из R2_SCENARIOS.md: reproducible analysis, actual oracle, CSV/XES equivalence, time policy, restart, list/identity, backup/restore corruption refusal, durable job cancellation/recovery. Новые изменения получают затронутые регрессии; пропущенные PG tests не являются новым restore proof. |
| R3-01 | Проекты и папки с жизненным циклом | Создать/переименовать/переместить/архивировать/восстановить; согласованная безопасная политика удаления; принадлежность/циклы/ссылки/session/current project; owner/editor/viewer/чужой пользователь. Долговечный restart и concurrent CAS в изолированном PG. |
| R3-02 | Долговечный audit | Actor/project/resource/action/policy/time/результат без секретов; атомарность mutation+audit, запрет подмены/чтения чужого, проверяемый порядок и bounded retention/export. Audit intent до фактической записи не выдается за audit успешной операции. |
| R3-03 | Сохранность, миграции и развёртывание | Новый schema/checksum, холодный backup/new restore/migrate, сбой/повтор/conservation и RBAC isolation на свежем тестовом кластере. Строгая политика неподдерживаемого downgrade. User installations остаются защищёнными. |
| R3-04 | Управляемая cleanup legacy-копии | Только explicit operator preview/backup/newrestore/offline lease; прерывание/продолжение/rollback/conservation без потери источника. DISK01 остаётся OPEN до этих доказательств. Native5.1 support не обещается до собственного полного прогона; если заявлен только PS7, это явно отражается в контракте. |
| R4-01 | Согласованный BPMN model contract и round trip | Конечный список node/edge/DI/label/condition/unsupported constructs утверждён заранее; import→edit→save→export→reimport сохраняет граф/семантику/позиции; duplicates/broken refs/namespace/limits/security отказывают; права и restart сохраняют модель. Исполняемый BPMN engine не входит в исходный roadmap автоматически. |
| R4-02 | Настоящий выбранный discovery miner | Алгоритм, provenance/version, параметры и supported model language названы; loops/concurrency/noise/empty logs и ограничения corpus проверены. Observed variants baseline не переименовывается в Split Miner или generalizing discovery. |
| R4-03 | Измеренное качество | Зафиксированные определения fitness/precision/simplicity и допуски, независимый evaluator/reference, training/held-out либо synthetic ground truth по согласованной методике. Счёт совпавших activity/counts не заменяет эти метрики; exact enumeration finite-language baseline не заменяет general Petri/BPMN conformance. |
| R5-01 | Фильтры выбранного Core coverage | Каждый выбранный фильтр имеет параметры/boundaries/composition/source preservation, actual legacy reference и frozen corpus. Список фильтров конечный и согласованный; отсутствие списка не разрешает объявить весь Core покрытым. |
| R5-02 | Business calendar IANA/DST | Пин версии tzdata/library, local schedule/holidays/weekends; явные gap/fold policies и actual spring/fall/DST/offset/overnight/invalid zone cases с независимыми expected UTC durations. FixedOffset не получает IANA credit. Legacy Calendar semantics отдельно сравниваются. |
| R5-03 | Conversions | Конечные пары и supported constructs названы заранее (например XES↔CSV, BPMN↔выбранная model representation); каждому преобразованию conservation/loss report/round-trip/unsupported refusal. Сериализация существующего graph subset не означает общий conversion coverage. |
| R5-04 | Split Miner | Реальный pinned upstream executable либо проверенный перенос алгоритма, не DFG/variants substitute. Замороженные noise/concurrency/loop corpora, параметры, graph semantics и отдельные quality/timing/memory comparisons. Порт зависит от BPMN/model contract и независимого evaluator. |

R2 закрыт только при PASS R2-01–04; R3 при PASS R3-01–04; R4 при PASS R4-01–03; R5 при PASS R5-01–04. Полное R2–R5 означает все эти пункты, без компенсации средним процентом. Если Council уточняет конкретный supported contract, изменённое определение голосуется отдельно и обозначается как уточнение, а не скрытая уступка шестичасовому сроку.

## Достижимая программа шести часов

Необоснованно обещать все пункты сегодня: full Manager service closure ещё не собран, platform folder/audit требует миграции и crash proof, real Split Miner/model quality не восстановлены, IANA semantics не реализованы. Предлагается работать до дедлайна по независимым потокам, максимизировать фактически закрытые пункты и сохранить оставшиеся как OPEN/BLOCKED с точной причиной. При неожиданно успешной ранней feasibility можно расширить реализацию, сохраняя 90 минут независимой приёмки.

| Время от старта | Этап | Результат |
|---|---|---|
| 0–30 минут | Council/matrix и feasibility | Exact source dependency gates fullservice и SplitMiner, selected conversions/model contract, corpus/manual expectations. Только подтверждённая реальная сборка даёт legacy credit. |
| 30–180 минут | Три независимых implementation потока | A: Root/operator import preview с source/action preservation; B: назначенный владелец platform folder/lifecycle/audit на отдельном schema/PG; C: назначенный владелец IANA calendar + deterministic quality/model contracts, параллельно feasibility pinned miner. Разделённые файлы; общие routes/schema/Cargo только через Root integration. |
| 180–270 минут | Интегрированный кандидат | Exact commit, meaningful negative/concurrency/restart/limits tests; отдельный свежий PG, no protected mutations; последняя реализация только при сохранении резерва. Если broad platform migration не доказана, она не попадает в поставку и не получает PASS. |
| 270–360 минут | Независимые QA/TD и поставка | Own cold replay/PG proof/CI/реальные votes; checked immutable source/package при runtime изменениях; independent public delivery and protected old health/artifact preservation. Отчёт с каждым R2–R5 пунктом, реальным elapsed и следующим blocker. |

Распределение — предложение председателю, а не поручение чужому исполнителю. При четырёх слотах root+два developer и параллельный QA используют все слоты; Customer/TD позиции собираются по очереди. Fullservice/SplitMiner feasibility выполняется назначенным developer в ограниченном начале, не новым бесконтрольным процессом. Independent QA не автор и не заменяет missing reference. Если платформенный поток и calendar/miner поток превышают budget, выбирается один готовый coherent increment, а недоделанные изменения отделяются от принимаемого кандидата.

## Контроль риска и остановка

Средний риск для изолированного нового кода; низкий допустимый риск потери пользовательских данных. Никаких login/config/DB mutation/stop/migrate/cleanup в прежних установках. Опасные процессы и сетевые источники — с prospective capture, private ACL, real exit/hash/time inventory; невозможность сборки сохраняется как diagnostic, не обходится stubs/редактированным upstream/переименованием baseline. STOP при identity gap, неподтверждённой миграции, unsafe mutation или false closure claim. Прежняя безопасная ветка и диагностика могут продолжаться.

PM позиция: продолжать предметную реализацию в шестичасовом лимите, но не обещать недоказанное полное закрытие. Эта матрица делает конечную цель проверяемой; после итерации любой незакрытый пункт получает владельца, зависимость и следующий acceptance gate.
