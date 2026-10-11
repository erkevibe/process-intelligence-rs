# Sprint07 — предварительный просмотр service-import

Окно четыре часа: 2026-10-11 02:52:21–06:52:21 UTC. План S7-P1 принят пятью фактическими голосами. Зафиксированы 11 примеров до исполнения; corpus SHA256 `49af9fb9c981ba77a49190211a1da1fbe1d9f9c4a595fc616754a2813f607b89`.

Добавлен отдельный Rust preview API/example: объяснённые удаления и default lifecycle с исходными trace/event номерами, source order, явный полностью пустой результат. Строгий parser и обычные HTTP imports используют прежний путь. Preview допускает отсутствие имени для объяснённого удаления, сохраняя raw limits/type/duplicate/XML/DTD отказы. Пользовательские проекты не изменяются. [Контракт и конкретный пример](SERVICE_IMPORT_PREVIEW.md).

Reference механически извлекает точные два метода upstream и выполняет их на реальных OpenXES типах. Это не запуск оригинального service-класса, Portal, persistence или importFromStream. Первые два draft-прогона: 11 исполнений каждый, 10 успешных; invalid-date воспроизводит `java.util.EmptyStackException`. Ручное сравнение11PASS: пять поддержанных policy scenarios, шесть explicit admission/error divergences. Эти цифры не являются общей долей совместимости.

| Критерий | Состояние |
|---|---|
| A01 exact method bytes/real OpenXES | Source28508байт/blob, slice1167байт/offset9172 закреплены; draft исполнения подтверждены; independent final replay ожидается |
| A02 fixed manual corpus | 11 literal inputs заморожены до запусков; full names/indices/cardinality/order/lifecycle/time/action comparisons draft PASS |
| A03 explicit preview | API/example + structured changes/fully_filtered; stability on normalized input/no mutation tested |
| A04 strict safety/regressions | Все прежние tests/clippy draft PASS, новые limits/cancel/negative checks; финальные checks ожидаются |
| A05 independent QA/TD/Council | Prospective controls и plan votes получены; integrated candidate audit ожидается |
| A06 public CI/delivery | Ожидается итоговый checked head/PR/source archive/preservation |

## Ход и границы

Feasibility подтверждён 02:58:25UTC, до03:32:21 gate. PM сохранил оба draft-прогона, затем усилил java/javac prebinding/per-invocation hashes/freshclass set и process metadata. Исполнение старого reference01 не выдаётся за проверку позднейшей версии runner. Root первое создание corpus/events остановилось на PowerShell синтаксисе inline here-string до исполнения; исправленная structured serialization выполнила freeze один раз. Первые широкие historical rg searches встретили ACL-denied и truncated output, не являются полным аудитом. Старый отсутствующий PM восстановлен новым отдельным агентом pm_s7; эмоциональный советник отдельный и без дополнительного голоса.

Полные private stdout/stderr/exit/source/class proofs находятся в SID-only `.local/sprint07`. Полное покрытие кандидата и реальные independent replay фиксируются отдельно. Пропущенные PostgreSQL tests не означают новый backup/restore proof. Ни один новый Windows пакет/релиз/установка не создаётся: приложение0.5 прежнее, библиотечный preview пока не подключён к UI/HTTP. DISK01 OPEN; native5.1 full backup UNVERIFIED; arbitrary upstreamXXE/full service/attributes/classifiers/calendars/DST/miner/BPMN quality не проверены.

Следующий прикладной шаг после принятия: отдельная защита пользовательского preview/подтверждаемого импорта в UI с сохранением исходного файла и audit trail. Операционная cleanup требует отдельной backup/newrestore/rollback цепочки.
