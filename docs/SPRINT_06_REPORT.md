# Sprint06 — XES reference

Лимит четыре часа: 2026-10-11 02:04:15–06:04:15 UTC. S6-P1 принят пятью независимыми голосами. Данный отчёт пока описывает проверяемый кандидат; финальная независимая приёмка и публичная доставка фиксируются отдельно.

Настоящие неизменённые OpenXES parser и LogParser XLog overload ApromoreCore запускаются без заглушек. Feasibility подтверждён до02:48:15; холодная сборка также воспроизведена. 134 upstream OpenXES исходника закреплены Git blob/SHA256, selective genuine closure129 классов. Public lock/standalone build helper получает primary source/dependency bytes, проверяет size/SHA/blob, выполняет compile/version/probe и сохраняет manifest.

Заморожены десять новых примеров до исполнения. Ручной Rust контракт прошёл: source/timestamp order, stable ties, UTC-equivalent offsets, lifecycle, отсутствующее/некорректное время, неправильный тип, duplicate semantic key, Unicode, empty trace и submillisecond precision. Девять Java примеров завершились exit0; invalid-time exit1 с upstream `EmptyStackException` явно сохранён. Три различия: принятие string timestamp, последнее duplicate-name и миллисекундная точность Java. [Точный контракт и воспроизведение](XES_ORACLE.md).

Шесть прежних входов сохранены без изменения и выполнены через настоящий XES parser; точный принятый0.5 EXE `4DA47C60DA169B2B0D659E4583A72EA5E17DBCE18B83E28B8923B2DF1CDAF98A` прошёл прежние ручные/новые actual consumer comparisons в отдельном ephemeral процессе. Это не запись в пользовательские проекты и не перенос приёмки на новую сборку.

Production src/Cargo/Windows helpers не изменены; новая Windows-упаковка не требуется. Поставка0.5 остаётся действующей. Новые example/tools служат developer conformance, не входят в приложение. Полные R2–R5, Portal/service validateLog, calendars/DST и miner/BPMN quality остаются частичными или непроверенными. DISK01 и native5 backup остаются открытыми.

## Матрица кандидата

| Критерий | Доказательство и состояние |
|---|---|
| A01 настоящий parser/consumer | build02 actual probe0; standalone cold04 fetch/compile/version/probe0, full313file proof |
| A02 immutable corpus | SHA8ebdb55f3a6a8c585865014c206d92be3d11e314925c52c1e7c6665ed9d14ac4; QA pre-run literal review |
| A03 actual outputs/Rust | 10 Java+20 Rust modes; actual six legacy regressions+accepted0.5 replay; final replay pending |
| A04 time/lifecycle/negative | literal expectations + separate source/time/error policies, actual upstream exception and three divergences |
| A05 independent QA/auditors | ранний независимый replay выполнен; окончательный freeze/replay/TD/голоса ожидаются |
| A06 public PR/CI | ожидаются exact final revision и публикация |

## Ход и ограничения аудита

Начальные source/clock/Git reads доступны только в tool outputs. Первое исполнение helper было недоступно из-за среды sandbox; разрешённый elevated путь сработал. Один guessed historical registry path отсутствовал, не является runtime ошибкой. Build01 выявил missing SLF4J; dependency закреплён по primary BOM, build02 прошёл. Cold03 отказал из-за неверно прочитанного tree identity; corrected primary commit→tree binding, cold04 прошёл. Run02 отказал на несовпадении формата manifest status; необязательное поле исправлено при сохранении обязательных hashes; новый run03 прошёл.

Старые private ACL raw-файлы первых попыток частично недоступны; audit coverage не выдаёт это за полный captured success. Cold04313 files полностью hashed. QA выявил verification gaps: независимые имена/кардинальности/precision/consumer counters и raw timestamp type/value; adapters усилены, прежние результаты сохранены. Final candidate replay должен подтвердить исправление этих gaps. Работа с реальными пользовательскими БД, cleanup/backup и package/install в этом спринте not-in-run.
