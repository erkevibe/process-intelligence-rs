# Sprint06 — XES reference

Лимит четыре часа: 2026-10-11 02:04:15–06:04:15 UTC. S6-P1 принят пятью независимыми голосами. Независимая техническая приёмка ограниченного oracle подтверждена на C2; финальные голоса, checked-head CI и публичная доставка фиксируются отдельными доказательствами.

Настоящие неизменённые OpenXES parser и LogParser XLog overload ApromoreCore запускаются без заглушек. Feasibility подтверждён до02:48:15; холодная сборка также воспроизведена. 134 upstream OpenXES исходника закреплены Git blob/SHA256, selective genuine closure129 классов. Public lock/standalone build helper получает primary source/dependency bytes, проверяет size/SHA/blob, выполняет compile/version/probe и сохраняет manifest.

Заморожены десять новых примеров до исполнения. Ручной Rust контракт прошёл: source/timestamp order, stable ties, UTC-equivalent offsets, lifecycle, отсутствующее/некорректное время, неправильный тип, duplicate semantic key, Unicode, empty trace и submillisecond precision. Девять Java примеров завершились exit0; invalid-time exit1 с upstream `EmptyStackException` явно сохранён. Три различия: принятие string timestamp, последнее duplicate-name и миллисекундная точность Java. [Точный контракт и воспроизведение](XES_ORACLE.md).

Шесть прежних входов сохранены без изменения и выполнены через настоящий XES parser; точный принятый0.5 EXE `4DA47C60DA169B2B0D659E4583A72EA5E17DBCE18B83E28B8923B2DF1CDAF98A` прошёл прежние ручные/новые actual consumer comparisons в отдельном ephemeral процессе. Это не запись в пользовательские проекты и не перенос приёмки на новую сборку.

Production src/Cargo/Windows helpers не изменены; новая Windows-упаковка не требуется. Поставка0.5 остаётся действующей. Новые example/tools служат developer conformance, не входят в приложение. Полные R2–R5, Portal/service validateLog, calendars/DST и miner/BPMN quality остаются частичными или непроверенными. DISK01 и native5 backup остаются открытыми.

## Матрица кандидата

| Критерий | Доказательство и состояние |
|---|---|
| A01 настоящий parser/consumer | build02 actual probe0; standalone cold04 fetch/compile/version/probe0, full313file proof |
| A02 immutable corpus | SHA8ebdb55f3a6a8c585865014c206d92be3d11e314925c52c1e7c6665ed9d14ac4; QA pre-run literal review |
| A03 actual outputs/Rust | Независимые16 genuine Java executions (15exit0/invaliddate1),20Rust modes и принятый0.5 six replay: scoped PASS |
| A04 time/lifecycle/negative | literal expectations + separate source/time/error policies, actual upstream exception and three divergences |
| A05 independent QA/auditors | ExactC2 QA/replay, public safe export и TD scoped ACCEPT; финальные голоса фиксируются отдельно |
| A06 public PR/CI | ожидаются exact final revision и публикация |

## Ход и ограничения аудита

Начальные source/clock/Git reads доступны только в tool outputs. Первое исполнение helper было недоступно из-за среды sandbox; разрешённый elevated путь сработал. Один guessed historical registry path отсутствовал, не является runtime ошибкой. Build01 выявил missing SLF4J; dependency закреплён по primary BOM, build02 прошёл. Cold03 отказал из-за неверно прочитанного tree identity; corrected primary commit→tree binding, cold04 прошёл. Run02 отказал на несовпадении формата manifest status; необязательное поле исправлено при сохранении обязательных hashes; новый run03 прошёл.

Старые private ACL raw-файлы первых попыток частично недоступны; audit coverage не выдаёт это за полный captured success. Independent cold313 files полностью hashed,134upstream blobs и504JDKfiles/noextras проверены. QA выявил verification gaps: независимые имена/кардинальности/precision/consumer counters и timestamp type/value; adapters усилены, прежние результаты сохранены. Оба QA-S6-01/02 закрыты независимым exactC2 replay. Coverage:502доступных/409565B,10недоступных явно перечислены. Работа с реальными пользовательскими БД, cleanup/backup и package/install в этом спринте not-in-run.

## Точные доказательства

C1 source `b0dcf126f076714d8571f65c759fa39591b4aebd`, Git archive SHA15478C325844FE3235129E71A4F880136D565FF14870940799E9DF7EF614A4D7; observer EXE E7C86243A7EB5DA6D55401E977839CF23D2D07B1BFF9A4E60672861B04206E3B. C2 `d0665a40f5389ce901100e2a20a7aed32f791c67` меняет только comparator и его описание; src/examples/Cargo/build helper/lock идентичны C1. Final documentary head отдельно от этих исполняемых доказательств.

Независимый QA: [position](../flw/evidence/sprint-06-qa-c2-position.md), JSON SHA466999F2B3C34385BB80A7EAD5D8BC3A8BA39FB3D3CCC1D955737EDC023C5FC4; [coverage](../flw/evidence/sprint-06-qa-c2-coverage.json), SHA95C187191DF9BC4912334FCE3696A2B20C007DCA37CAC62E2CAA5B03DF40CDAF. Public safe projection audit CAD97CFE36AE81AAA1B11BFCD496FD50AAEE0B502C885A271B09F92ABD2F546B.

Фактические безопасные результаты: [10 XES reference](../fixtures/oracle-xes/reference-results.json), [20 Rust modes](../fixtures/oracle-xes/rust-comparison.json), [шесть прежних регрессий](../fixtures/oracle-xes/original-six-results.json). Полные upstream source/jars/raw stderr остаются приватными; original raw report SHA указаны в projections. Local clippy0 и обычные Rust tests0;13PostgreSQL scenarios ignored/not-in-run для evidence-only sprint. Provenance guards5PASS; final CI проверяет тот же скрипт.

[Независимый TD](../flw/evidence/sprint-06-td-final.md), SHAB57BCEC988C881C4E0606B7336E9C6FE5F0B291943EB6B7C8EDC0398BA14DC5C, подтверждает закрытие verification причин в выбранном контракте. [Source equivalence](../flw/evidence/sprint-06-source-equivalence.json): production diff0 от compiled55e8 через принятую35f0 доC2,70ordinary tests PASS/13ignored. Raw-хешированные Sprint06 evidence сохраняют исходные байты через `.gitattributes -text`; line-ending normalization не меняет доказательства при публикации.
